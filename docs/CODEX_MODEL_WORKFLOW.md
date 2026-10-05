# GLory：给 Codex 执行的 3D 角色模型精修工作流

把本文件和完整项目交给 Codex，指定角色，即可开展诊断、制作、接入和测试。目标是**角色更容易区分、结构和材质更精美、符合种族与职业设定，并在本地真实游戏中成立；手机表现按本次测试范围另验**。允许精修原模型，也允许制作新资源替换；面数增加、工具安装或代码检查通过都不等于目标完成。

本文是普通 Markdown 执行说明，不需要安装成 skill。项目入口与研究来源复核日期为 **2026-10-03**；后续使用必须以当前代码、实际资源和工具版本为准。第 9 节记录首个样板，不能当作其他角色已验收。

## 1. 怎样交接与执行

同事需要本 MD、本地 `GLory-v1.0` 源码及角色实际引用的模型、贴图、动作资源。先按 `docs/WORKSPACE-LAYOUT.md` 核对目录；部分美术另由资源包分发，仅有源码不一定资源齐全。缺少资源时列出具体路径，从已授权交付源补齐，保留本地较新文件；不使用占位模型完成验收。

最低环境是项目匹配的 Godot；制作可编辑模型使用 Blender，构建工具使用 Python 3.10+；Android 测试还需要匹配的导出模板、SDK、JDK、ADB。复用已有环境，先看目标脚本 `--help` 和 `--check`，不为单个模型重装整个工具链。

在项目聊天中粘贴，至少填写“对象”：

```text
阅读并执行 docs/CODEX_MODEL_WORKFLOW.md。
对象：<角色名称 / unit_id，例如 god_guard 光之卫士>
问题：<辨识度低、造型粗糙、材质糊；可以补参考图>
方向：<保持种族与角色设定；或明确指定风格/配色>
范围：<单个角色；或一组角色逐个验收>
测试环境：<默认本地 Godot 编辑器；可选填写手机>
允许精修原资源或新增替换，保留回退版本，先使用免费本地工具。
本次允许安装必要免费工具并在本地 Godot 编辑器测试；手机测试仅在明确指定且设备可用时进行；不改变玩法、动作时序和挂点契约。
请先加载真实模型和同族角色比较，再制作、实际预览、接入并测量。
不满意就依据画面指出问题、修改并复验。交付可编辑源、可重跑脚本、前后对比和测试证据。
不要自动提交、推送、发布、同步远端或上传私有素材到第三方服务。
```

批量任务建立 `unit_id / 设定 / 原场景 / 候选资源 / 缺陷 / 状态 / 证据` 清单。每个角色独立验收；共同族色不是让全族共享同一轮廓。

### 跨平台与本地测试（默认路径）

支持 Windows 和 macOS。以收到的本地 `project.godot`、代码和资源为事实源：可以来自本地副本、压缩包或版本库，不要求 GitHub、特定提交号、`.git` 或联网同步。先备份将修改的文件并记录资源路径/哈希；存在 Git 时可额外记录差异。文中项目入口是查找线索，本地布局不同就沿真实引用调整，不能为匹配文档覆盖本地资源。

**没有手机也能完成本次本地验收。** 在 Godot 项目管理器中导入本地 `project.godot`，等待资源导入完成，打开 `scenes/debug/ModelRefinementPreview.tscn`，按 F6（运行当前场景）循环观察。不要双击场景文件启动另一个项目，也不要为预览改正式主场景。再运行项目的真实战斗入口，验证正式路由、动画、挂点和多单位效果；使用调试器/性能监视器记录本机数据，保存同条件前后截图或录像。离线截帧和 headless 检查不能代替实际画面与实时性能观察。

验收分为“本地编辑器与正式路线”和“可选真机”。本地范围内画面、契约、路由与性能检查通过即可写“本地验收通过；真机未测试（本次未纳入）”。没有手机时跳过 Android/iOS 构建、安装与设备采样，不安装 SDK/JDK/ADB，不等待设备。仅当本次明确包含手机测试且设备可用时执行真机章节；不能把桌面结果写成手机性能结论。

Windows 使用 PowerShell，Godot 路径指向实际 `.exe`（需要终端日志时可选 console 版本），Blender 指向 `blender.exe`；macOS 指向应用包中的实际可执行文件。Python 命令按本机使用 `py -3` 或 `python3`。下方 Bash 命令用于 macOS/Linux；Windows 不直接粘贴 Bash，按示例使用调用运算符 `&`，路径有空格时保留引号。每一步检查退出码和产物，失败即停，不继续后续命令。

Windows 编辑器启动示例（先替换为真实路径）：

```powershell
$MODEL_PROJECT = "D:/Projects/GLory-v1.0"
$MODEL_GODOT = "D:/Tools/Godot/Godot.exe"
$MODEL_OUT = "D:/Deliveries/model-review"
Set-Location "$MODEL_PROJECT"
& "$MODEL_GODOT" --editor --path "$MODEL_PROJECT" "res://scenes/debug/ModelRefinementPreview.tscn"
```

## 2. 先锁定角色与项目契约

### 2.1 工作区与执行范围

1. 找到包含 `project.godot` 和实际资源/代码目录的项目根目录；不要求 `.git`，路径以操作者本机为准。
2. 阅读适用 `AGENTS.md`，备份本次将改动的文件并记录本地基线。若存在 Git，额外记录状态与差异；没有 Git 时使用文件副本和哈希比较。保留已有工作，不全局 reset/clean，不批量覆盖资源。
3. 核对 Godot `--version`、实际渲染器、导出预设、模型和动作源是否齐全。项目声明 Godot 4.7；按本次实际测试平台的渲染器和 3D 视口尺寸验收；手机另测。
4. 既有授权覆盖必要的本地制作、免费工具安装与本地测试（或已指定的手机测试）时直接推进。新工具先核对来源、许可和本机支持；付费服务、第三方上传、远端发布不由本 MD 自动授权。

### 2.2 追踪事实源

| 内容 | 首选入口 | 要确认什么 |
|---|---|---|
| 单位、种族、元素、职业与技能 | `data/units/race_units.json`，对应玩法实现与设计文档 | 用稳定 ID 消除中文简称歧义；技能和定位约束外形 |
| 模型接入约定 | `docs/模型接入方法.md` | 文档可能滞后，继续读当前资源和代码 |
| 正式资源解析 | `effects/runtime/presentation/UnitVisualResolver.gd` | `model`、`model_by_element`、视觉字段覆盖及旧回放处理 |
| 模型、缩放与挂点 | `effects/runtime/presentation/UnitActor3D.gd`，正式 `BattleRenderer` 调用 | 脚底、施法、命中位置、朝向、包围盒和动画入口 |
| 动画包装场景 | 数据表实际指向的 `.tscn` / GLB / FBX 与脚本 | 真正显示哪个 mesh，动作是否切换模型，材质覆盖在哪层 |
| 材质与贴图导入 | 实际 `.tres` / Shader / `.import` | 图像源尺寸、运行尺寸、压缩、mipmap、光照算法 |

制作前写一张约束卡，记录以下内容及来源路径：

```text
unit_id / 正式名称 / race / element / 职业和技能定位：
必须保留的轮廓、武器、体型、颜色；允许改变的部件：
与哪些同族角色最相似；新设计准备建立哪 2～3 个可见识别点：
原模型路径、各动作实际资源、材质和贴图、版本/哈希：
骨架数量、骨名/层级、绑定姿势；动作名、时长、循环、根位移：
play_idle/play_run/play_attack 等包装接口与正式攻击同步参数：
缩放、朝向、落地、FootAnchor/CastAnchor/命中挂点及计算方式：
固定比较镜头、背景、光照、画质、分辨率和战斗阵容：
预期同时可见单位数、性能基线和验收预算：
```

神族沿用项目已有白色主视觉与允许的暖金细节；元素和职业通过结构、器具、材质分区表达。用户明确指定颜色/风格时记录覆盖，不擅改种族或属性。`god_guard` 是光之卫士、神族地系坦克，不是 `god_priest` 神侍；应强调稳定、防御与守护，不凭名字增加翅膀或改成治疗法师。

## 3. 加载真实模型，判断“不好看”来自哪里

### 3.1 先留公平基线

打开当前正式模型，实际播放 idle/run/attack。保存近景三分之四、正/侧/背、实际战斗距离及关节极限姿势；固定相机、灯光、背景、分辨率、缩放、动作时间、渲染器。修改后使用相同条件，不能把新模型的棚拍与旧模型的战斗缩略图比较。

正面方向用实际眼睛、脚尖、武器和骨骼姿态确认，不凭 `model_base_yaw` 或静态 AABB 猜测。正式游戏的朝向补偿与美术正面可不同；本轮已发现 180° 误标，旧错误截图保留为失败证据，最终对照重新采集。截图元数据应含 unit_id、实际资源、镜头、朝向、动作名与准确采样秒数。

再把目标与至少两个最容易混淆的同族角色放在同一画面：先看无名字的轮廓/灰度，再看正常材质。必要时给全族做联系表，记录身宽、头肩形状、武器、背部和站姿差异。辨识点必须在游戏实际显示尺寸下可见。正式战斗镜头从高处看：玩家看到的己方单位主要是**背面和头顶**，敌方才是正面；识别点至少要在背面/俯视下成立（暗族批次中，法师光环在敌方正面被兜帽挡住，但在己方背面最醒目）。

### 3.2 分开诊断，不先加面

| 现象 | 需要检查 | 对应改进 |
|---|---|---|
| 全族像同一个人 | 小尺寸剪影、体型、器具、主次形状 | 先改比例和 2～3 个职业识别部件，颜色只作辅助 |
| 身体像圆柱或玩具 | 甲片厚度、倒角、关节和软硬材质边界 | 调整真实几何与部件层次，不只加发光线 |
| 表面糊或缺细节 | 源图与运行贴图尺寸、UV 利用率、纹理过滤、压缩 | 局部调整导入/UV/纹理，不全局提高全部贴图 |
| 面颊、肩袖、衣摆出现黑点或黑块 | 实际材质引用、UV 对应源像素及 alpha、岛边缘留白、运行压缩/mipmap；同时排查法线、重叠面和阴影 | 确认根因后修贴图空白/边距或对应几何，按 3.3 复验 |
| 有纹理却显平 | 实际 Shader 是否使用法线/粗糙度/高光，法线方向 | 调整角色专属材质；不要为一个角色改坏共享 Shader |
| 曲面明显多边形 | 近景与战斗距离轮廓、法线断裂、实际三角数 | 修法线或有选择加密曲面/倒角，以可见收益决定 |
| 动起来穿插、拉长 | 蒙皮权重、骨骼挂接、动作极限、运行根位移 | 修权重和部件位置，静态 AABB 不能证明动画包覆正确 |

盘点 mesh/surface 数、顶点与三角面数、骨架与骨数、材质、纹理运行尺寸和 draw calls。UV 缝或硬边会拆顶点，顶点数不等于三角面数；文件体积也不等于显存。给出 2～4 项有截图支持的主要缺陷，再选择制作路线。

### 3.3 黑点、黑块与贴图空白的排查和预防

模型精修前后都要检查脸颊/领口、肩袖、衣摆和 UV 接缝。**材质存在、贴图加载成功、骨架检查通过，并不证明贴图内容正确。** 神侍曾保留原图中的不透明纯黑空白，UV 采到这些区域后呈现黑洞状斑块；仅改善 Shader 未消除根因。

1. **定位来源。** 沿正式包装器确认每个动作实际使用的材质和贴图，将缺陷位置映射到 UV/源图，检查 RGB 与 alpha。区分原图黑色空白、过滤/mipmap 越界采色、合法深色纹样，以及法线、重叠面、背面剔除或阴影问题；不能见黑就统一提亮或删面。
2. **保留原图，局部修复。** 确认为未绘制空白时，独立生成修复贴图，用同一表面邻近有效颜色补绘，处理黑色边缘并为 UV 岛保留足够采样边距。邻近区域属于不同材质时应手工限定区域或重新烘焙；不得无差别填充所有深色像素。保留眼睛、眉毛、墨线、金属暗部及有意的透明度，不靠增强灯光、发光或全局增亮掩盖问题。
3. **验证最终导入。** 将实际运行材质切换到修复图，重新导入；核对运行尺寸、压缩、过滤和 mipmap。源图放大看着正常仍可能在缩小或压缩后出黑边，必须在 Godot 最终渲染设置下检查近景与战斗距离。确认 idle/run/attack 都读取修复资源。
4. **保存复验依据。** 同镜头采集正/侧/背与三动作，复查原缺陷及面部细节、衣褶边缘。可记录缺陷 UV 采样前后颜色、修改区域、源图/修复图哈希和 alpha 一致性；少量采样通过不能替代整模型视觉检查。确认无非预期黑斑、串色或细节丢失后才通过。
5. **同步交付。** 更新可编辑 `.blend` 中的贴图、运行材质、资源包和哈希清单，保留原图、复现命令及前后画面。旧截图、录像和性能数据须标记对应资源版本；没有重新测量的性能结果不得写成本次实测。

神侍案例与复现命令见 [MODEL_REFINEMENT_GOD_PRIEST.md](MODEL_REFINEMENT_GOD_PRIEST.md) 的“黑斑修复追加验收”。`tools/model_refinement/repair_priest_atlas.py` 使用 Pillow/NumPy 为该角色图集补齐大块近黑空白；其中颜色、连通区域面积和扩边阈值仅针对这张图调校。用于其他角色前必须重新核验掩码，不能把“小块一定是眼睛、大块一定是空白”当作通用规则。

AI 生成图集常见三个隐患：岛与岛之间是**不透明黑色**（`fix_alpha_border` 无效，低 mip 会把黑边混进细小岛，造成颗粒/黑楔）；全图 alpha=255 却按 RGBA 压缩（显存翻倍）；烘焙时把肤色串到头发/披风边缘。整族统一乘色或压暗会掩盖第三项，一旦提亮材质就会露出来。修法是按真实网格 UV 光栅化覆盖区、只对覆盖区重采样并向外扩边、按三角朝向修补串色，存 RGB；不要靠再压暗来藏。

## 4. 免费工具与开源资料怎样选

主路径是 **Blender 原生建模/bpy → 可编辑 `.blend` → GLB 与贴图 → Godot 包装场景**。已有 Godot 程序几何也可用，但必须有真实可编辑几何与可复现参数。工具只解决已发现的缺口，无需安装整张清单。

| 来源 | 借鉴内容 | 使用边界 |
|---|---|---|
| [Blender 官方](https://www.blender.org/) | 比例、倒角、拓扑、UV、权重、PBR、烘焙；`--background --python` 可重跑 | 优先匹配的稳定版本；批处理无需先安装 MCP |
| [arjun988/blender-skills](https://github.com/arjun988/blender-skills)（MIT） | character-artist 的先比例后细节，godot-export 与截图 QA | 借鉴方法，保留本项目动作名与接口；其通用命名和预算不能直接替代项目契约 |
| [cc-blender-skill](https://github.com/RobLe3/cc-blender-skill)（MIT） | [质量迭代方法](https://github.com/RobLe3/cc-blender-skill/blob/main/plugin/skills/quality-refinement-autoloop/SKILL.md)：保存失败证据、诊断、修复和复验 | 作者自述测试不等于本项目兼容证明；不照搬客户端工具名 |
| [MCP for Blender](https://github.com/ahujasid/mcp-for-blender)（MIT） | 交互检查视口、对象、材质，执行 bpy | 原 blender-mcp 已更名；可选。核心免费，Premium/第三方生成 API 另计；本次不默认上传素材 |
| [Material Maker](https://github.com/RodZill4/material-maker)（默认 MIT，例外另查） | 金属、布料、雕纹等程序纹理与绘制 | 保留节点源，优先烘焙 PBR 贴图；不解决轮廓、骨架或动画 |
| [RetopoFlow](https://github.com/CGCookie/retopoflow) / [Instant Meshes](https://github.com/wjakob/instant-meshes) | 拓扑确有问题时整理网格 | 不会自动精美化，也不保证保留 UV/权重。RetopoFlow 许可元数据有不一致且非代码资产另有权利；Instant Meshes 官方预编译为 Intel64，Apple Silicon 未验证。本流程不强制依赖 |

引入时记录 URL、作者、工具版本或文件哈希、许可原文、安装路径和用途；复制代码或素材时保留要求的版权声明，素材独立许可单独核对。不要把代码 MIT 等同于所有云服务和资产免费。

Blender 选用与本地制作脚本兼容的版本，根据 Windows/macOS 和 CPU 架构选择安装包；已有可用版本优先复用。无需安装某个固定 macOS 构建，变更版本后先试跑导出并检查结果。

## 5. 制作：结构先行，细节分层

1. **比例和主轮廓。** 先完成可辨识的黑色剪影，落实职业识别点。坦克可用坚实胸肩、稳定下肢与防御器具体现定位；具体设计必须与现有角色动作及设定一致。
2. **中尺度部件。** 处理甲片叠层、肩/胸/腰的承接、器具厚度和倒角。用几何表现会改变轮廓和遮挡的结构。配件不能悬浮、过度对称复制或覆盖所有关节。
3. **表面细节。** 用材质分区、粗糙度、法线和适度雕纹建立白色甲壳、金属、布料的区别。主识别线在小尺寸下仍要清楚，微细噪声不能导致手机闪烁。提高分辨率前确认 UV 与导入限制确实是瓶颈。
4. **控制光照。** 保持基线灯光，使用局部材质实例/专属 Shader。高光要显结构，发光不能把形体洗成纯白。不得用更强灯光、景深、Bloom 或特效遮盖几何问题。战斗主光偏暖（约 1.0/0.84/0.62）：条带高光若乘光色，大平面（翼膜）和浅色发丝会出现成片棕褐色块；冷色调种族的高光只取光强、颜色由材质定。
5. **必要时重拓扑/烘焙。** 先保存高模与原始绑定版本；高模细节烘焙至游戏网格的法线/粗糙度，轮廓细节保留几何。检查 UV 接缝、cage、法线方向、mipmap 边距。自动重网格后重新转移和检查权重，不假设动画仍正确。
6. **保存可编辑源。** 保留 `.blend`、制作脚本/参数、原资源引用、GLB、材质与必要贴图。仅截图或渲染视频不构成模型交付；仅挂配件也不能自动证明主体比例和材质已改善。

每轮只解决已记录的主要缺陷，重拍同条件对比。若主轮廓还不清楚，先修轮廓；若真实 Shader 丢失细节，先修材质路线。禁止通过无目的 subdivision、随机切割或装饰堆叠追求“更多面”。

[Blender 重网格说明](https://docs.blender.org/manual/en/4.5/modeling/meshes/retopology.html)说明其主要改变网格密度和拓扑；[烘焙说明](https://docs.blender.org/UATEST/manual/en/4.5/render/cycles/baking.html)说明高低模法线烘焙条件。这些工具能力不能替代角色设计。

## 6. 保留动画与正式接入

- 优先保留现有骨架、骨名/父子关系、绑定姿势和动作库；新增刚性护甲/器具绑定适当骨骼，软部件需要正确权重。检查是否给原有动画层重复套变换。
- 替换或压缩蒙皮网格时，还需保留所有 blend shape 名称、模式及逐顶点形变通道；动画可能引用 `V_None` 等表情轨道。仅保留骨骼和权重仍会导致 AnimationMixer 缺失目标。神侍试做曾触发此错误，修复后须再次检查三个实际动作。
- 三份动作 FBX/GLB 的包装器里，**不同动作文件可能是不同绑定**：同一身体被重新导出到别的空间、换了骨骼朝向，甚至换了骨架命名（魅魔 run 前移 0.141；末日守卫 idle/attack 为 Mixamo 65 骨、run 为 CC 83 骨且整体高 0.844）。先导出每个动作骨架的 rest/bind 并比较，再决定零件做几套；按“该骨在该骨架皮肤里的 bind pose 一致”来挂零件，不匹配就报错，不要按动作名猜。
- 刚性零件不要每骨一个 `BoneAttachment3D` + MeshInstance：它会让常驻 surface 按“骨数 × 动作数”增长（黑龙一度 12 > 硬上限 6）。把同一骨架的零件合成**一个蒙皮 surface**：顶点存为骨局部坐标、100% 权重到所属骨、bind 为单位矩阵，交给引擎蒙皮，相同骨架共享同一网格。
- 比对所有已有动作的名字、长度、循环、轨道目标、根位移与攻击触发点。至少真实播放 idle/run/attack；受击/死亡有专用动作时也测，没有时保持既有处理，不为验收伪造新动作。
- 保留 `play_idle()`、`play_run()`、`play_attack()` 等当前包装接口。不要照搬外部 skill 将动作改名 `AN_*`；不要用静态姿势或程序摆动替换原有蒙皮动作。
- 比较身体与配件在跑步、抬手、攻击末端的相对位置，检查漂浮、穿插、脚滑、断层及镜像朝向。保留脚底/施法/命中挂点与技能包覆；修模型不应让此前护盾和武器落在错误位置。
- 导出时验证绑定姿势、三角化、法线/切线、材质、纹理和动画。只应用适当的几何修改器，不把 Armature 当静态网格烘掉。[Godot 导出约定](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_3d_scenes/model_export_considerations.html)以 +Z 为角色正面；项目现有旋转补偿仍以运行结果为准。
- [Godot 推荐 glTF/GLB](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_3d_scenes/available_formats.html)。OBJ 不携带骨架/动画；`.blend` 直接导入依赖本机 Blender。团队交付优先保留 blend 制作源，同时导出独立运行 GLB，避免手机样板依赖制作软件。Blender 批处理使用 `--python-exit-code 1`，同时确认导出文件存在、体积与内容正确；进程返回 0 不能单独证明导出完成。版本变化时先检查操作符参数，本轮 4.5 使用 `export_vertex_color`，不接受旧 `export_colors` 参数。
- 可保留原始包装场景引用，在新包装层使用精修 mesh/材质；也可新建候选资源后仅切换目标的模型视觉映射。记录 `原路径 → 新路径 → 正式调用`，不能只修改没有被调用的预览。
- 修改数据表时严格限制为本次需要的视觉字段。`UnitVisualResolver.VISUAL_FIELDS` 是代码实现，不是任意改值许可；不得顺便改 `tier`、费用、伤害、血量、范围、移动/攻击速度、技能目标或回放规则。攻击同步与挂点契约本次保持不变。
- 材质不要污染共享资源，原新模型不要重复叠加显示。正式战斗与备战/图鉴若使用同一映射，分别确认显示正确；旧版本保留在本地备份或明确的参考目录中。

## 7. 验证本地画面、路由与性能（手机可选）

### 7.1 技术检查覆盖正确对象

先读现有工具覆盖范围，再选相关检查：`tools/model_material_integrity_check.gd`、`tools/model_bounds_check.gd`、`tools/model_asset_budget_check.gd`、`tools/model_action_contract_report.gd`、`tools/model_action_playback_continuity_check.gd`、`tools/model_root_motion_inventory_check.gd`。复用 `tools/model_visual_matrix_capture.gd` 做适当画面采集。检查导入错误；有 Git 时运行 `git diff --check`。

刚性附件跟骨运动正确也不证明它不穿模或好看。新增甲片须与原身体的曲率、倒角、金属明暗及细节密度协调；本轮四件附件的 184 项技术断言通过，但箱形肩甲和棕色金属仍被视觉审查淘汰。

技术通过只证明其断言覆盖的资源/契约；无关检查全绿、像素有变化、骨骼数量相同都不证明美观或动画正确。

headless 运行检查时一律加超时（如 `timeout 900`）：场景脚本若有解析错误，Godot 会在无脚本的情况下一直空跑，不会退出也不会报 CHECK_RESULT。工具注释里写 `res://` 示例路径会被 `asset_manifest_check` 当成缺失引用，示例用占位符。预览若要与正式战斗一致，须对 `model_in_place_actions` 套用同一 `ModelRootMotionPolicy`，否则会看到正式路线里不存在的跑步前冲。`battle_presentation_baseline` 的固定阵容里第 1/3 回合是 PvE，B 队（含暗族）不上场；要让 B 队出现须跑 PvP 回合（`data/rounds/round_schedule.json`，如 6、21）。

当前工具有明确覆盖边界：`model_bounds_check` 使用 `load_idle_only`，不证明 run/attack 的动态轮廓；`model_visual_matrix_capture` 的矩阵是 idle/attack/hit/death，缺 run，且其配置检查要求 Mobile，不能代替 Compatibility 真机结果；`model_action_playback_continuity_check` 只选中配置了 `model_in_place_actions` 包含 run 的对象，目标未配置时可能被跳过。始终检查报告实际枚举了本次 unit_id 和动作，空覆盖不能过关。

### 7.2 循环预览与视觉判定

必检项：按 3.3 检查面部、肩袖、衣摆和 UV 接缝的非预期黑点/黑块；覆盖最终导入设置下的正侧背、近景/战斗距离和 idle/run/attack。眼睛等有意深色细节须保留。发现黑斑未定位或未修复时，视觉验收不通过。

专用入口为 `res://scenes/debug/ModelRefinementPreview.tscn`。执行前确认文件与依赖存在，再在 Godot 编辑器打开运行；不要修改项目正式主场景来启动样板。预览提供原/新模型、近景/战斗距离与真实动作观察；截帧时不用 `--headless`。

`ModelRefinementPreview.gd` 的目标（原/新路径、比例、美术正面、同框阵容）现由可覆写的目标表提供，默认仍只有 `god_guard`；暗族八个单位用子类 `scenes/debug/DarkRaceRefinementPreview.tscn`（`--unit dark_<id>`，`--lineup` 为全族同框，比例/三阶放大/原地动作从数据表读取），见第 10 节。**当前提供的预览和下方命令是 `god_guard` 样板。** 它的原/新路径、同族对照和标题有角色配置，不会因聊天中写“神侍”就自动换模型。测试其他角色前，创建该角色的预览并明确配置目标 ID、旧/新路径、缩放、动作、朝向及对照角色；构建时必须同时传 `--unit-id`、`--preview`、`--old-model`、`--new-model`，runner 也要传同一个 `--unit-id`，完整命令见 7.4。先检查日志、画面标题和加载资源都对应目标，再开始手机矩阵。默认样板支持 `--unit god_guard` 核验，传入其他 ID 会拒绝执行，防止成功测完错误对象。新预览须保留同样的身份校验：性能请求必须包含 `unit_id`、`old_model_path`、`new_model_path`，三项与预览配置及非空 `model_build_info.json` 一致；构建指纹也必须非空。纯交互预览不要求性能请求或构建信息。

```bash
MODEL_PROJECT="/本机路径/GLory-v1.0"
MODEL_GODOT="/本机路径/Godot可执行文件"
"$MODEL_GODOT" --editor --path "$MODEL_PROJECT" \
  res://scenes/debug/ModelRefinementPreview.tscn
```

Windows PowerShell 等价命令（同样先填写本机路径）：

```powershell
$MODEL_PROJECT = "D:/本机路径/GLory-v1.0"
$MODEL_GODOT = "D:/本机路径/Godot可执行文件"
& "$MODEL_GODOT" --editor --path "$MODEL_PROJECT" `
  res://scenes/debug/ModelRefinementPreview.tscn
```

交付前逐项查看画面并给出具体结论：

- 在实际战斗距离，无名字也能凭体型与器具区别目标和最相似同族角色。
- 近景有明确甲片厚度、结构衔接、材质分层；没有靠碎片堆积制造噪声。
- 正/侧/背均完成，idle/run/attack 期间没有明显穿插、脱落、脚滑或错误蒙皮。
- 实际项目灯光和低成本渲染设置下仍清楚；高光、白色和发光不过曝，纹理不闪烁。
- 与固定基线相比，逐项说明原缺陷如何改善，并提供相应图像。美术结论是执行者的有证据评估，不声称用户已满意。

### 7.3 正式路线验证

进入真实 `BattleScreen`，通过正式单位定义与表现解析创建目标，触发移动和攻击；记录单位 ID、实际加载资源与同时间画面。检查同族同屏、UI 遮挡、朝向和技能挂点。只在专用场景手动实例化新资源不算正式接入证据。

固定阵容经过真实模拟器和回放进入战斗，可证明这条本地路线；在线传输与手机完整战斗负载仍需各自证据。不得为方便展示改变正式伤害、阵容规则或随机流。

### 7.4 可选：独立 Android 样板（无手机跳过）

使用 `tools/build_model_refinement_pilot.py` 与 `tools/run_model_refinement_pilot.py`。先看当前 `--help`，确认预览已经实现。构建默认只收集依赖，`--build` 才导入/导出；runner 的 `--check` 只读。以下路径由操作者填写，产物置于项目外层新目录：

```bash
MODEL_PROJECT="/本机路径/GLory-v1.0"
MODEL_GODOT="/本机路径/Godot可执行文件"
MODEL_OUT="/本机路径/delivery/model-目标角色-日期"
MODEL_SERIAL="从 adb devices -l 读取的精确序列号"
cd "$MODEL_PROJECT"
python3 tools/build_model_refinement_pilot.py --help
python3 tools/run_model_refinement_pilot.py --help
python3 tools/build_model_refinement_pilot.py --check --godot "$MODEL_GODOT"
python3 tools/build_model_refinement_pilot.py --build --godot "$MODEL_GODOT" \
  --unit-id god_guard --out "$MODEL_OUT/android-build"
python3 tools/run_model_refinement_pilot.py --check --serial "$MODEL_SERIAL" \
  --unit-id god_guard --build-dir "$MODEL_OUT/android-build" --out "$MODEL_OUT/android-run"
python3 tools/run_model_refinement_pilot.py --serial "$MODEL_SERIAL" \
  --unit-id god_guard --build-dir "$MODEL_OUT/android-build" --out "$MODEL_OUT/android-run"
```

Windows PowerShell 等价命令（同样先填写本机路径）：

```powershell
$MODEL_PROJECT = "D:/本机路径/GLory-v1.0"
$MODEL_GODOT = "D:/本机路径/Godot可执行文件"
$MODEL_OUT = "D:/本机路径/delivery/model-目标角色-日期"
$MODEL_SERIAL = "从 adb devices -l 读取的精确序列号"
Set-Location "$MODEL_PROJECT"
py -3 tools/build_model_refinement_pilot.py --help
py -3 tools/run_model_refinement_pilot.py --help
py -3 tools/build_model_refinement_pilot.py --check --godot "$MODEL_GODOT"
py -3 tools/build_model_refinement_pilot.py --build --godot "$MODEL_GODOT" `
  --unit-id god_guard --out "$MODEL_OUT/android-build"
py -3 tools/run_model_refinement_pilot.py --check --serial "$MODEL_SERIAL" `
  --unit-id god_guard --build-dir "$MODEL_OUT/android-build" --out "$MODEL_OUT/android-run"
py -3 tools/run_model_refinement_pilot.py --serial "$MODEL_SERIAL" `
  --unit-id god_guard --build-dir "$MODEL_OUT/android-build" --out "$MODEL_OUT/android-run"
```

Windows 实测注意（2026-10-05，暗族/灵族模拟器测试）：

- `--out` 必须是纯英文路径：Java `keytool` 遇到 `桌面` 这类非 ASCII 路径报 “Bad pathname”（工具现会提前拒绝）。先输出到英文目录，证据再复制进交付目录。
- `--godot` 可直接给 `_console.exe`，工具会把同目录主程序一并复制进 `runtime/`（console 版只是启动器）。Windows 上通常还要显式给 `--java-home`、`--android-sdk`；runner 要显式给 `--adb` 和 `--aapt`（`build-tools/<版本>/aapt.exe`）。
- Android 模拟器的 GLES 翻译层读不回 Godot 缓存的着色器二进制，每次启动都打印 `WARNING: Failed to load cached shader, recompiling.`；runner 只在模拟器（`ro.kernel.qemu`/`ro.boot.qemu` = 1）上放过这一行，真机仍按任何 WARNING 判失败。刚装完 APK 第一次写请求偶尔读回不一致，重跑即可。
- 同一台设备同一时间只能有一个 runner。在 Git Bash 里中止脚本不一定连带结束子进程，重跑前先确认没有残留的 `run_model_refinement_pilot.py`；交叠运行的数据全部作废。
- 无真机可用 Android SDK 模拟器（WHPX）。新版 cmdline-tools 用 `android.exe` 代替 `sdkmanager`：`android sdk install system-images/android-34/google_apis/x86_64`。`android emulator create <profile>` 会**自行下载**它选的系统镜像，要用指定镜像就改 AVD 的 `config.ini`。模拟器首次进入全屏应用会弹系统提示，测量前先关掉。模拟器 GPU 是主机显卡翻译层，帧时间不代表手机，只证明 GLES/Compatibility 下能安装、加载、渲染且日志无错。

例如准备测试神侍时，先完成神侍专用预览和候选模型，再填写以下三个真实路径；不要把光之卫士预览改个文件名就当作已换角色。此处路径变量均须指向已经存在、正确配置的资源，尚未制作时不能执行：

```bash
MODEL_UNIT="god_priest"
MODEL_PREVIEW="res://填写神侍专用预览.tscn"
MODEL_OLD="res://assets/models/units/god_priest_halo_animated/god_priest_animated.tscn"
MODEL_NEW="res://填写神侍候选模型.tscn"
python3 tools/build_model_refinement_pilot.py --check --godot "$MODEL_GODOT" \
  --unit-id "$MODEL_UNIT" --preview "$MODEL_PREVIEW" \
  --old-model "$MODEL_OLD" --new-model "$MODEL_NEW"
python3 tools/build_model_refinement_pilot.py --build --godot "$MODEL_GODOT" \
  --unit-id "$MODEL_UNIT" --preview "$MODEL_PREVIEW" \
  --old-model "$MODEL_OLD" --new-model "$MODEL_NEW" --out "$MODEL_OUT/android-build"
python3 tools/run_model_refinement_pilot.py --check --serial "$MODEL_SERIAL" \
  --unit-id "$MODEL_UNIT" --build-dir "$MODEL_OUT/android-build" --out "$MODEL_OUT/android-run"
python3 tools/run_model_refinement_pilot.py --serial "$MODEL_SERIAL" \
  --unit-id "$MODEL_UNIT" --build-dir "$MODEL_OUT/android-build" --out "$MODEL_OUT/android-run"
```

Windows PowerShell 等价命令（同样先填写本机路径）：

```powershell
$MODEL_UNIT = "god_priest"
$MODEL_PREVIEW = "res://填写神侍专用预览.tscn"
$MODEL_OLD = "res://assets/models/units/god_priest_halo_animated/god_priest_animated.tscn"
$MODEL_NEW = "res://填写神侍候选模型.tscn"
py -3 tools/build_model_refinement_pilot.py --check --godot "$MODEL_GODOT" `
  --unit-id "$MODEL_UNIT" --preview "$MODEL_PREVIEW" `
  --old-model "$MODEL_OLD" --new-model "$MODEL_NEW"
py -3 tools/build_model_refinement_pilot.py --build --godot "$MODEL_GODOT" `
  --unit-id "$MODEL_UNIT" --preview "$MODEL_PREVIEW" `
  --old-model "$MODEL_OLD" --new-model "$MODEL_NEW" --out "$MODEL_OUT/android-build"
py -3 tools/run_model_refinement_pilot.py --check --serial "$MODEL_SERIAL" `
  --unit-id "$MODEL_UNIT" --build-dir "$MODEL_OUT/android-build" --out "$MODEL_OUT/android-run"
py -3 tools/run_model_refinement_pilot.py --serial "$MODEL_SERIAL" `
  --unit-id "$MODEL_UNIT" --build-dir "$MODEL_OUT/android-build" --out "$MODEL_OUT/android-run"
```

每步成功后再执行下一步。样板使用独立包 `com.glory.modelpilot`，正式 `com.glory.game` 仅查询；不卸载、不清数据、不用正式签名。重复构建如需沿用已安装样板签名，使用构建工具的 `--debug-keystore` 指向先前样板调试密钥，不通过卸载规避签名冲突。

运行前后核对源码指纹、APK 哈希、runtime run_id、实际视口与动画模式。过期 APK、未完成 JSON、后台暂停、错误日志或缺组数据不能判通过。测量期间不修改依赖资源；修改后重新构建。runner 报告测量完成，仍须检查画面和预算。

当前默认四组为旧 6 单位 30 秒、新 6 单位 30 秒、旧 12 单位 30 秒、新 12 单位 180 秒，各先预热 2 秒；正常验收开启真实动画。此矩阵用于初筛，若需要比较长期温升，补充相同时长旧/新或交换顺序复测，不能用不同持续时间的热状态下结论。

记录机型、系统、GPU、实际 3D 分辨率、渲染器、帧率目标、电量/温度、p50/p95、>100 ms 长帧、draw calls、三角数、内存与节点趋势；无采集能力的指标写未测。正式预算先查项目，暂无约定时将相同条件 p95 增长 >10%、重复长帧、稳定帧率跨档或内存/节点持续增长作为调查线，不能测后放宽标准。

保持主轮廓和材质层次，优先减少无贡献背面、透明叠层、碎材质、重复纹理与过度细分，再考虑 LOD；有收益的面数增加允许保留。样板性能良好不等于完整游戏达标；手机正式验收还需本次游戏构建中真实目标与其他单位/UI/特效一起运行，保留画面和负载证据。

## 8. 失败迭代与交付

画面不达标时保存该轮版本和证据，明确是哪一项失败：设定/识别、比例/轮廓、部件、UV/材质、动画、正式接入或性能。先修改对应方法和本 MD 的相关条目，再修模型，使用相同条件复验；不要不断换灯光或堆细节掩盖根因。失败候选保留作证据，不能标为正式完成。

每个角色交付一套可编辑源与运行资源，证据建议放项目外层 `delivery/model-<unit_id>-<日期>/`，避免录屏被导入游戏。报告至少包含：

```text
角色约束卡与同族对照；旧问题 → 改善 → 对应画面：
制作工具/版本、外来资源来源许可；blend、脚本、GLB/场景和贴图路径：
原/新顶点、三角数、surface/材质、运行纹理尺寸及新增成本原因：
正式视觉映射和回退方法；玩法/骨架/动作/挂点对比结论：
同镜头多视角、战斗尺寸、三动作前后对比与循环录屏：
技术检查实际覆盖与结果：
分别标记：桌面预览 / 正式战斗路线 / 独立手机样板 / 手机正式战斗：
设备、源码/APK哈希、实际渲染条件、旧新性能与未测项：
本轮失败及修正；视觉结论、尚存限制；下一位同事的复制命令：
```

清理旧资源前先查 `assets.manifest.json` 的分类与 `required_by`：清单分类可能已过期（如女王已换 `*_smooth.fbx`，清单仍记旧 FBX 为 runtime_required）。`unit` 模型目录被 git 忽略、经资源 ZIP 分发；只删工作区文件时，`restore_assets.ps1` 会把它们还原，`asset_delivery_check` 会报缺失。重做基准（`update_asset_manifest.ps1` + `package_assets.ps1`）会一并吸收所有未提交的资源漂移，属于资源负责人的决定；删除前把文件和哈希完整备份到交付目录，并在 `docs/assets/` 记录增删清单。

代码通过但视觉缺陷仍在，继续改。手机仅安装成功或样板完成，不能写成完整战斗验收。若外部条件确实阻塞，交付已有可核实证据并清楚保留待验证项；不要借技术通过宣称用户审美满意。

新角色试用必须重新追到实际包装器。例如神侍当前让 idle/run/attack 三份 FBX 常驻并逐个显示，且脚本给各 surface 强制覆盖同一个身体材质；只精修 idle 或给 FBX 添加未被读取的 PBR 贴图，会在换动作时回到旧模或被材质覆盖。先检查每个真实动作显示路径，再决定合并骨架或同步精修，不能把光之卫士的单骨架实现直接套上去。包装层代理动作的名称/时长也可能不同于内层 FBX 真正播放的片段；必须记录两者映射与实际播放器，不根据外层标签擅自重命名或裁剪动作。

## 9. 首个样板：光之卫士 `god_guard`

初版记录日期 **2026-10-03**。角色事实来自 `data/units/race_units.json`：神族、地系、近战防御定位，技能 `guardian_shield_taunt`。原场景为 `res://assets/models/units/god_guard_crystalbound/god_guard_crystalbound_animated.tscn`，原包装接口已有 idle/run/attack。

本轮开始盘点：原 mesh **4,409 顶点 / 3,018 三角面**，**1 个骨架 / 83 骨**；主源图 **2048**，当前导入限制 **512**；实际材质使用双档 toon 明暗且无高光。该记录描述特定原模型与导入状态，不能据此认定缺陷只有面数不足，也不能当作新增配件后的总成本。应结合实际截图区分几何、贴图导入和材质响应的贡献。

本轮保留 `model_attack_sync_seek=0.35`、`model_attack_lock_time=0.45`、`model_base_yaw=180` 和现有玩法值；可新增精修资源，通过目标视觉映射接入。研究记录在本次外层交付目录的 `research.json`；本 MD 的工具表保留关键来源，交接不依赖该记录才能执行。

### 9.1 本轮已制作与接入

- 候选入口：`res://assets/models/units/god_guard_refined/god_guard_refined.tscn`。正式 `race_units.json` 只修改 `god_guard.model` 一个字段。回退时恢复本节开头的原场景路径即可；原资源未覆盖。该新场景继承原 `god_guard_crystalbound_animated.tscn`，脚本也继承原包装器，原目录及其依赖仍是运行必需；仅复制 refined 目录无法运行。`guardian_armor.glb` 只含四组附件，不含身体、骨架和动作。
- 身体沿用原网格、UV、权重、Godot 骨架的 83 个骨节点与三动作。角色专属材质将原 atlas 从运行 512 调整为 1024，减轻硬阴影和描边，增加受控的暖金高光；没有伪造不存在的法线贴图。本样板仍是自定义风格化光照，并非完整 PBR 重制。Godot 4 的自定义 `DIFFUSE_LIGHT` 与 `ALBEDO` 分工以[官方 spatial shader 文档](https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html)为准；本轮去除了新 shader 中重复乘色造成的暗棕，角色共享 shader 未改。
- Blender 制作了弧面塔盾及背板、弧形肩甲、额头晶石；四组刚性几何按原骨名挂接，共用一个附加材质。盾牌是模型结构，守护技能特效仍走原有 VFX 入口。
- 最终运行统计：**7213 顶点 / 8538 三角面 / 5 surfaces / 3 个唯一材质（含身体描边）/ 最大纹理 1024**。原版 3018 面，增长主要用于盾牌弧面和倒角，属于约 2.83 倍三角数的单角色试点，不能直接全族照搬；是否保留由本次目标平台的同条件结果决定。
- `tools/model_refinement_contract_check.gd --require-integrated`：**185 项通过**，覆盖原资源 SHA、身体几何/蒙皮、骨架/rest、动画轨道与实际姿态、四附件的 36 个跟骨采样、材质独立、预算和正式映射。报告为交付目录 `audit/model-contract-v4-integrated.json`。
- 对 MD 做了另一角色的盲读试用，修正“换了角色却仍测默认光之卫士”、缺失身份字段仍能启动、三 FBX 只改 idle 和强制材质覆盖等问题。身份与文档修复验证 **50 项通过**，记录 `audit/workflow-blind-trial.json`；它不是第二个角色的美術制作验收。

### 9.2 从失败中修正的做法

| 轮次 | 发现 | 决策与证据目录 |
|---|---|---|
| 01 材质 | 清晰度改善，但轮廓几乎不变 | 继续结构制作；`iteration-01-material` |
| 02 盒形护甲 | 技术检查通过，肩甲却像棕色箱体，盾像纸板 | 视觉淘汰；`iteration-02-geometry-front` |
| 03 弧面肩甲 | 肩甲协调，盾仍平，额冠埋在旧头盔内 | 弧面盾与真实蒙皮表面测量；`iteration-03-curved-front` |
| 04 弧盾 | 正面改善，但背面大片金色、俯视轮廓弱 | 补盾背板/筋条，适当外移；`iteration-04-back` |
| 05 完整表面 | 身体细节、白金层次、防御器具与晶石识别点成立 | 正/侧/背 idle/run/attack 复核；`iteration-05-front/side/back` |

当前美术判断是比原版更清楚、职业辨识更直接，达到这次单角色样板的改善目标。背肩旧饰片与新壳交界仍可进一步整理，原悬浮碎晶也保留；这些是后续精修点，不能宣称模型已经重做成高端手工角色，也不代替用户最终审美判断。

### 9.3 制作与重跑命令

历史样板的制作源和证据位于项目外层 `delivery/model-workflow-20261003/`。DCC 使用已核验的 Blender 4.5.14 LTS，`source/guardian-original.glb` 和 `source/guardian-original-rig.json` 是从实际原场景导出的参考及坐标契约。生成脚本为 `tools/model_refinement/build_guardian_armor.py`；输出包含可编辑 blend、GLB 与部件清单。

最终可直接打开的是 `source/guardian_refined_editable.blend`：22 个新增部件已在 Blender 中真正附骨，原纹理已打包。`source/parent_guardian_editable_parts.py` 是不导出 runtime 的源文件后处理；它验证静止变换、四骨分别旋转 17° 的跟随、还原及保存后重开，报告 `source/guardian_editable_check.json` 全部通过。静止矩阵最大误差约 `2.09e-7`；原动作关键帧和原几何不变。Godot 有 83 个骨节点，导出的 GLB skin 与 Blender data.bones 为 82，`RL_BoneRoot` 作为根对象另计；这是格式表示差异，不能误报丢骨。Blender 材质用于编辑参考，最终画面仍以 Godot 专属 shader 和运行 1024 纹理验证。

```bash
MODEL_PROJECT="/本机路径/GLory-v1.0"
MODEL_GODOT="/本机路径/Godot可执行文件"
MODEL_OUT="/本机路径/delivery/model-review"
MODEL_BLENDER="/本机路径/Blender可执行文件"
cd "$MODEL_PROJECT"
mkdir -p "$MODEL_OUT/audit" "$MODEL_OUT/source"
# 将本地项目的源文件工具复制到交付目录，再操作交付源文件：
cp tools/model_refinement/parent_guardian_editable_parts.py "$MODEL_OUT/source/"
cp tools/model_refinement/export_guardian_editable_parts.py "$MODEL_OUT/source/"
"$MODEL_BLENDER" --background --python-exit-code 1 \
  --python tools/model_refinement/build_guardian_armor.py -- \
  --source "$MODEL_OUT/source/guardian-original.glb" \
  --rig-json "$MODEL_OUT/source/guardian-original-rig.json" \
  --out "$MODEL_OUT/source/refinement-rebuild"
# 为制作源补正确附骨，保留未经后处理的原 blend：
"$MODEL_BLENDER" --background --python-exit-code 1 \
  --python "$MODEL_OUT/source/parent_guardian_editable_parts.py" -- \
  --source "$MODEL_OUT/source/refinement-rebuild/guardian_refinement.blend" \
  --output "$MODEL_OUT/source/guardian_refined_editable.blend" \
  --report "$MODEL_OUT/source/guardian_editable_check.json"
# 检查文件和清单，复制候选 GLB 到对应角色目录后重新导入；再执行：
"$MODEL_GODOT" --headless --path "$MODEL_PROJECT" \
  --script res://tools/model_refinement_contract_check.gd -- \
  --require-integrated --out "$MODEL_OUT/audit/model-contract-final.json"
"$MODEL_GODOT" --path "$MODEL_PROJECT" --rendering-method gl_compatibility \
  --resolution 1440x900 --always-on-top res://scenes/debug/ModelRefinementPreview.tscn -- \
  --unit god_guard --close --view front --capture-dir "$MODEL_OUT/final-front"
```

Windows PowerShell 等价命令（同样先填写本机路径）：

```powershell
$MODEL_PROJECT = "D:/本机路径/GLory-v1.0"
$MODEL_GODOT = "D:/本机路径/Godot可执行文件"
$MODEL_OUT = "D:/本机路径/delivery/model-review"
$MODEL_BLENDER = "D:/本机路径/Blender可执行文件"
Set-Location "$MODEL_PROJECT"
New-Item -ItemType Directory -Force -Path "$MODEL_OUT/audit", "$MODEL_OUT/source" | Out-Null
# 将本地项目的源文件工具复制到交付目录，再操作交付源文件：
Copy-Item tools/model_refinement/parent_guardian_editable_parts.py "$MODEL_OUT/source/"
Copy-Item tools/model_refinement/export_guardian_editable_parts.py "$MODEL_OUT/source/"
& "$MODEL_BLENDER" --background --python-exit-code 1 `
  --python tools/model_refinement/build_guardian_armor.py -- `
  --source "$MODEL_OUT/source/guardian-original.glb" `
  --rig-json "$MODEL_OUT/source/guardian-original-rig.json" `
  --out "$MODEL_OUT/source/refinement-rebuild"
# 为制作源补正确附骨，保留未经后处理的原 blend：
& "$MODEL_BLENDER" --background --python-exit-code 1 `
  --python "$MODEL_OUT/source/parent_guardian_editable_parts.py" -- `
  --source "$MODEL_OUT/source/refinement-rebuild/guardian_refinement.blend" `
  --output "$MODEL_OUT/source/guardian_refined_editable.blend" `
  --report "$MODEL_OUT/source/guardian_editable_check.json"
# 检查文件和清单，复制候选 GLB 到对应角色目录后重新导入；再执行：
& "$MODEL_GODOT" --headless --path "$MODEL_PROJECT" `
  --script res://tools/model_refinement_contract_check.gd -- `
  --require-integrated --out "$MODEL_OUT/audit/model-contract-final.json"
& "$MODEL_GODOT" --path "$MODEL_PROJECT" --rendering-method gl_compatibility `
  --resolution 1440x900 --always-on-top res://scenes/debug/ModelRefinementPreview.tscn -- `
  --unit god_guard --close --view front --capture-dir "$MODEL_OUT/final-front"
```

手工编辑使用另一条入口：上面的生成器从原 GLB 和脚本参数重新建附件，**不会读取最终 editable blend 的手工改动**。在 Blender 中修改 `.blend` 后，用已交付的 `source/export_guardian_editable_parts.py` 导出附件，不能直接把整个场景导出后覆盖游戏 GLB。此工具使用原 Godot rest JSON 转换坐标，按四个 `bone_name` 合并，保留顶点 `Color`、法线和一个共享材质，排除原身体、骨架与动画；颜色应修改 `Color` 属性，单改 Blender 材质基础色不会改变运行专属 shader。

```bash
"$MODEL_BLENDER" --background --python-exit-code 1 \
  --python "$MODEL_OUT/source/export_guardian_editable_parts.py" -- \
  --source "$MODEL_OUT/source/guardian_refined_editable.blend" \
  --rig-json "$MODEL_OUT/source/guardian-original-rig.json" \
  --output "$MODEL_OUT/source/manual-edited-armor.glb" \
  --manifest "$MODEL_OUT/source/manual-edited-manifest.json"
```

Windows PowerShell 等价命令（同样先填写本机路径）：

```powershell
& "$MODEL_BLENDER" --background --python-exit-code 1 `
  --python "$MODEL_OUT/source/export_guardian_editable_parts.py" -- `
  --source "$MODEL_OUT/source/guardian_refined_editable.blend" `
  --rig-json "$MODEL_OUT/source/guardian-original-rig.json" `
  --output "$MODEL_OUT/source/manual-edited-armor.glb" `
  --manifest "$MODEL_OUT/source/manual-edited-manifest.json"
```

先审查导出，再把该 GLB 替换角色目录的 `guardian_armor.glb`、重新导入，执行资源契约和本地多角度动作检查；本次包括手机时再重新构建。手改后不能继续使用修改前的性能报告。未手改源的回导已完成隔离 Godot 检查：**37 项通过**，四组附件实际附骨后的逐三角世界几何、绕序、顶点色、法线、AABB 与锁定 runtime 一致，最大误差 0；报告为 `source/editable-export-equivalence.json`。该报告证明无损回导，不自动证明后续手工编辑美观。

同样采集 `--view side`、`--view back`、不带 `--close` 的 `--view battle`，以及 `--compare`、`--lineup`。这些实际渲染命令会自动保存四帧及准确动作时间后退出；`--smoke` 只检查加载和动作，不产生视觉通过结论。

### 9.4 历史正式页面与手机证据（手机命令可选）

正式页面采集须使用隔离工程与独立用户目录，避免修改操作者存档。`model_refinement_prep_capture.gd` 验证正式 PrepScreen 路由、棋盘/候补不同星级与脚底；`--validate-fixture` 可预先检查阵位。按正式 Prep 的 `prep_visual_root` 元信息定位实例，记录实际路径。固定阵容要检查自动合成：本轮两个 1 星同名卫士进备战后合成，测试错误地等一个已被合并的候补；改为 1/2/4 星并验证合成阈值、实际星级和逐节点状态后通过。等待超时须输出哪个槽位缺失/隐藏/未居中，不能只给笼统失败。

完整手机战斗使用独立包 `com.glory.modelbattlepilot`，真实调用 `FixedBattleFixture → BattleSimulator → GameState.pending_battle_package → BattleScreen`。它是本地固定回放，保留正式单位/UI/模型/特效负载，关闭不需的网络与语音权限；不证明线上联机行为。

```bash
python3 tools/build_model_battle_pilot.py --godot "$MODEL_GODOT" \
  --out "$MODEL_OUT/android-battle-build" \
  --expected-model res://assets/models/units/god_guard_refined/god_guard_refined.tscn --build
python3 tools/run_model_battle_pilot.py --serial "$MODEL_SERIAL" \
  --build-dir "$MODEL_OUT/android-battle-build" --out "$MODEL_OUT/android-battle-run"
```

Windows PowerShell 等价命令（同样先填写本机路径）：

```powershell
py -3 tools/build_model_battle_pilot.py --godot "$MODEL_GODOT" `
  --out "$MODEL_OUT/android-battle-build" `
  --expected-model res://assets/models/units/god_guard_refined/god_guard_refined.tscn --build
py -3 tools/run_model_battle_pilot.py --serial "$MODEL_SERIAL" `
  --build-dir "$MODEL_OUT/android-battle-build" --out "$MODEL_OUT/android-battle-run"
```

桌面正式路线已完成：`formal-prep-old/new` 分别记录真实备战 5 个模型，卫士为 1/2/4 星，模型映射、idle 与脚底居中均通过；`formal-battle-old/new` 分别记录真实 BattleScreen 固定战斗及四帧截图，解析器确实加载原/新场景，守护技能特效继续正常走正式入口。桌面截图中的启动 FPS 不用于性能比较，下面独立手机矩阵才是本轮帧时证据。

真机为 vivo V2527A / Android 16 / Adreno 829，Compatibility，实际 3D 视口 **1600×720**（手机屏幕 2640×1216 不等于渲染尺寸），真实动画开启，每组先预热 2 秒；测试全程电量 100%，设备电池温度 36.5→36.8°C（不作为 CPU/GPU 结温）：

| 模型数 | 旧版测量时长 | 新版测量时长 | 旧 p95 | 新 p95 | p95 变化 |
|---|---:|---:|---:|---:|---:|
| 6 | 30 秒 | 30 秒 | 17.753 ms | 17.964 ms | +1.19% |
| 12 | 30 秒 | 180 秒 | 18.137 ms | 18.237 ms | +0.55% |

四组均无 >100 ms 长帧；12 人新版 25 个循环末的节点数均为 196。p50 约 16.58–16.59 ms。该试点未触发 §7.4 的 +10% p95 调查线，支持保留本次局部结构成本；旧/新持续时间不同，不能据此宣称长期温升或所有中低端机型都相同。draw calls 峰值 6 人为 69→93，12 人为 81→129；必须记录新增四附骨 mesh 的绘制成本。

构建和手机首装还修复了三项可复用问题：旧 FBX 源 `.fbm` 路径缺失须先以实际动作/材质审计确认覆盖有效，不能笼统忽略导入错误；未安装独立包时 `pm path` 的返回码 1 应按未安装处理；首次启动前应通过 `run-as` 建立包内 `files` 请求目录。这些均记录首轮失败并补回归，正式游戏包未更改。

原始指标：`android-run/model_pilot_perf.json`；设备、APK/源码指纹和正式包前后核对：`android-run/run-report.json`。手机完整战斗也已通过：`android-battle-run/run-report.json` 为 `offline_battle_presentation_verified`；`evidence.json` 及 5 张 2640×1216 引擎截图证明真实 actor 只加载精修场景、同一动画播放器的 idle/run 实际推进，并观察到 attack 开始播放、24 帧固定回放到达末端、原护盾和嘲讽特效仍在正式路线中出现。模型缩放 0.42，83 骨节点、5 mesh/5 surfaces、8538 面。源码/APK 核对通过，最终 Android runtime log 无运行错误。该验证证明离线正式表现路线与共存负载，未做完整战斗帧时基准或线上网络回归。正式回放采样中的 attack 位置只捕获到 0，不能声称该报告证明了整段攻击播放；完整三动作循环由独立手机录像及资源契约的九组实际姿态补充验证。固定阵容也未自然耗尽护盾。

独立测试前后，手机正式 `com.glory.game` 保持 0.0.15（22）及原 APK SHA，没有卸载、清档或替换。供查看的循环留在 `com.glory.modelpilot`；实际手机 A/B 录屏为 `android-run/device-ab-loop.mp4`（采样结束后录制，约 16 秒），桌面近景为 `guardian-refined-loop.mp4`。正式战斗截图期间出现过瞬时 20 FPS，末帧为 61；采集包含截图读回和 PNG 写入，本轮未隔离这些成本，不能宣称整局稳定 60 FPS，也不能直接归因于模型。桌面正式旧/新采集退出都记录了 Godot 的 ObjectDB/ParticlesShader 清理诊断，作为既有退出问题保留，不能称所有平台日志零告警。

本轮完成状态：**MD 已经实际试用、修正并验证；光之卫士精修样板已通过资源/动画契约、桌面多视角、真实备战、独立手机矩阵和手机真实战斗表现验证。** 最终审美仍由用户判断；后续角色、低端设备、多人整局与长期热稳定性须按本文重新测量。

## 10. 暗族批次：八个单位 `dark_*`

记录日期 **2026-10-04**，范围由用户确认：八个一起做；暗紫为种族主色，复审后要求**全族颜色统一**、魅魔与痛苦女王不要偏粉；黑龙保持人形；不按阶位改体型，仅魔童缩小；本轮只做本地验收，之后全设备验证；清理未使用旧资源。证据与可编辑源在项目外层 `delivery/model-dark-race-20261004/`。

### 10.1 诊断（基线 `captures/old/`）

八份材质除阴影色外完全相同（统一乘紫 0.84/0.76/0.96、无高光/法线/自发光），图集运行时 512（三张 4096 源缩 8 倍），全族在战斗距离是同一团暗紫。每个动作 FBX 约 3,000 面，面数不是瓶颈。八个单位双眼骨中点都在头骨 +Z 侧，`model_base_yaw=180` 正确；早期矩阵截图里的“背面”是高机位俯视大发型/披风。三阶在正式战斗另有 ×1.2（`BattleRenderer.TIER3_VISUAL_BOOST`），原始模型高度本身都在 1.82～2.05。

### 10.2 做法与结构

- **接入**：`assets/models/units/dark_refined/<id>/<id>_refined.tscn` 实例化**未改动**的原包装器，加一个 `DarkRefinement` 子节点；`race_units.json` 只改 8 个 `model` 与魔童 `model_visual_scale 1→0.85`。回退＝改回原路径（见 `docs/assets/dark_race_refinement_20261004.json`）。
- **材质**：`shared/dark_body.gdshader`（暗族专属，共享 `character_toon` 未改）：去掉统一乘紫，`value_lift` 按 sqrt 提亮暗部不改色相；**统一色板**——饱和颜色（粉、橙、金）按饱和度沿色环拉向种族紫 `race_hue≈277°`（默认 0.85，魅魔/女王 0.95），低饱和的皮肤、白发、钢色保留；各单位只按自己图集的色相带决定“哪些细节发光”，发光与边缘光一律同一紫色；浅色饰边只取光强的冷色条带高光；末日守卫用已有的烘焙法线。参数表在 `tools/model_refinement/dark_race_materials.py`（`RACE_HUE`/`RACE_GLOW`）。
- **贴图**：`tools/model_refinement/dark_race_textures.py` 按真实 UV 覆盖重采样、扩边、修补黑龙后/顶部发丝的肤色串色，输出 1024 RGB（DXT1/ETC2，比原 512 DXT5 每张多约 0.4 MB）。原图集保持不动。
- **识别零件**（Blender 5.1，`tools/model_refinement/build_dark_parts.py`，可编辑源 `source/<id>/parts/<id>_parts_source.blend`；所有发光件同一紫色）：魔童尾尖发光桃心；暗影法师头后符文光环；偷袭者背负镰刀（刃越过头顶）；魅魔桃心尾；恐惧魔骨色卷角；痛苦女王荆棘冠；末日守卫胸背两道魂链（链接技能）；黑龙后掠龙角、收拢龙翼与龙尾。零件按骨架 bind 匹配导出（魅魔/末日 run 各有第二套），运行时每个动作骨架合成一个刚性蒙皮 surface。

| 单位 | 原常驻三角 | 新常驻三角 | 可见增量 | 识别点 |
|---|---:|---:|---:|---|
| 魔童 | 3,122 | 3,150 | +28 | 缩小 0.85、尾尖桃心 |
| 暗影法师 | 9,351 | 12,039 | +896 | 符文光环 |
| 偷袭者 | 9,267 | 10,179 | +304 | 背负镰刀 |
| 魅魔 | 9,099 | 10,047 | +316 | 桃心尾 |
| 恐惧魔 | 9,045 | 11,367 | +774 | 骨色卷角 |
| 痛苦女王 | 9,162 | 11,511 | +783 | 荆棘冠 |
| 末日守卫 | 9,312 | 12,012 | +900 | 魂链、法线 |
| 黑龙 | 9,030 | 21,426 | +4,132 | 龙翼、龙角、龙尾 |

常驻＝三个动作模型之和（隐藏动作也常驻）；全部在 `model_asset_budget` 硬预算内（黑龙 hero 档 surfaces 6/6）。

### 10.3 验证（本地）

- `tools/dark_refinement_contract_check.tscn -- --require-integrated`：**710 项通过**——原包装器运行所需文件哈希未变、骨架/rest/身体网格/全部片段与原版一致、每个动作骨架使用精修材质与刚性蒙皮零件、备战 idle-only 实例同样成立、贴图 ≤1024 且无 alpha。
- 既有检查：`model_asset_budget`、`model_bounds`、`model_material_integrity`（报告列出 8 个精修路径）、`model_root_motion_inventory`、`model_action_playback_continuity` 通过；`texture_import_budget` 只检查固定 8 张贴图，**不覆盖**本批贴图。
- 正式路线：`scripts/qa/battle_presentation_baseline.tscn` 跑 PvP 第 6、21 回合（第 1、3 回合为 PvE，暗族不上场），新旧数据各一次：6 个上场暗族单位真实加载精修场景、actor 契约完整、0 回退；`simulation_replay_sha256`、`final_state_sha256`、`frame_events_sha256` 新旧**完全相同**（玩法不变），仅 payload 因 `def.model` 改变。魔童、痛苦女王不在固定阵容中，其路由由数据契约与预览覆盖。
- 桌面同条件（Compatibility，1280×720，同一代码版本、仅切换数据）：p95 9.09→9.26 ms（R6、R21）；峰值 draw calls 435→446、439→451；纹理显存 +3.4 MB；>100 ms 长帧 1→1。真机未测；2026-10-05 在 Android 模拟器上测了黑龙（见 §11.5），6/12 个原版与新版均通过、日志无错误、draw calls 每个 +2。模拟器帧时间不代表手机，黑龙仍是手机上的首要观察对象。复审期间仓库合入了上游提交（crimson 更新等），合入前后第 21 回合模拟本身就不同；新旧对照必须在同一代码版本上只切换 `race_units.json`，否则会把别人的改动误判为本批的影响。

### 10.4 本轮失败与修正

| 轮次 | 发现 | 修正 |
|---|---|---|
| 01 材质 | 法师整体变成平淡淡紫；黑龙背上出现棕褐色条 | 法师不提亮、边缘光减弱；串色改为贴图修补 |
| 02 零件 | 魅魔尾/恐惧魔角/末日锁链看不见（颜色与身体同暗或埋进护甲） | 骨色/渐变色、宽半径贴面采样、加大链环 |
| 03 | 法师光环发粉、与魅魔撞色；俯视下翼膜大片棕褐 | 冷色“arcane”光环；高光只取光强 |
| 04 | 光环挂胸随身体前倾偏出头部；顶部发丝仍有串色 | 光环改挂头骨；修补规则加顶面朝向 |
| 05 动作 | 末日攻击时过肩链条漂在空中；镰刀杆尾甩出 | 链条只在躯干；镰刀杆缩短、刃加大 |
| 预算 | 黑龙每骨一个挂点 → 12 surfaces > 6 | 合成单一刚性蒙皮 surface |
| 复审 | 用户：颜色要统一；魅魔、女王偏粉 | 统一色板（色相拉向种族紫、单一发光色）；零件取消橙/蓝/粉；发光紫降低红分量，避免亮处溢成粉 |

### 10.5 清理与待办

删除 68 个运行时未使用的暗族文件（284.7 MiB：根目录原始 GLB/JPG、末日旧 FBX 与重复贴图、女王非 smooth FBX），全部按哈希备份在 `delivery/.../removed-assets/`；魔童 `attack_punching.fbx` 因 `BattleRenderer.gd` 仍有字面量而保留。`assets.manifest.json`/`assets.bundle.json` **未改**：重做基准会同时吸收 19 个与本批无关的既有尺寸差异，由资源负责人决定（见第 8 节）。

尚存限制：敌方正面看不到法师光环（被兜帽挡住）；末日攻击中段链条侧视；魅魔桃心与恐惧魔卷角在己方俯视背面不明显；统一色板后魅魔/女王/魔童不再靠颜色区分，主要靠轮廓与零件，魔童尾尖在战斗距离不如橙色醒目；备战界面仅做结构验证，未单独截图；手机性能未测。

### 10.6 重跑命令（Windows，先替换路径）

```powershell
$P = "D:/本机路径/GLory-v1.0"; $G = "D:/本机路径/Godot_v4.7-stable_win64_console.exe"
$B = "D:/本机路径/blender.exe"; $D = "D:/本机路径/delivery/model-dark-race-20261004"
# 1 导出原始骨架/身体参考（每个单位一次，--model 填原包装器）
& $G --headless --path $P --script res://tools/model_refinement/export_unit_reference.gd -- --model <原包装器> --unit-id dark_dragon --out "$D/source/dark_dragon"
# 2 贴图、零件、材质与场景
py -3 "$P/tools/model_refinement/dark_race_textures.py" --refs "$D/source"
bash "$P/tools/model_refinement/build_dark_parts_all.sh" "$B" "$P" "$D/source"
py -3 "$P/tools/model_refinement/dark_race_materials.py"
& $G --headless --path $P --import
# 3 契约与画面
& $G --headless --path $P res://tools/dark_refinement_contract_check.tscn -- --require-integrated --out "$D/audit/contract.json"
& $G --path $P --rendering-method gl_compatibility res://scenes/debug/DarkRaceRefinementPreview.tscn -- --lineup --view battle
```

`tools/model_refinement/capture_dark_race.sh <godot> <project> <out> old|new` 批量采集全部视角（`VIEWS`/`LINEUP` 环境变量可缩小范围）。最终审美仍由用户判断。

## 11. 灵族批次：八个单位 `undead_*`

记录日期 **2026-10-04**，用户确认：八个一起做；全族统一为毒绿（小灵、毒灵、寄生灵的绿）；不改体型（小灵本身已小）；识别零件按计划；所有设备都要测（本机无真机，先用模拟器）；共用文件**原地复用**，不另建中性目录。证据在 `delivery/model-undead-race-20261004/`。

### 11.1 诊断

与暗族同样的模板问题：8 份材质只差阴影色、统一乘偏绿色、无高光/边缘光；图集 4096 → 运行 512；岛间不透明黑缝。灵族特有：颜色分裂成毒绿（75–105°）与橙棕/琥珀/芥末黄（30–60°），母灵整件斗篷为芥末黄；毒灵、寄生灵、刺灵同为“兜帽 + 头顶绿火 + 披风”。三份动作文件共用同一身体与骨架（无需第二套零件），朝向均为 +Z，每动作约 3,000 面。

### 11.2 做法（复用第 10 节工具，按种族参数运行）

- 工具原名原地扩展为多种族：预览 `DarkRaceRefinementPreview`（`RACES` 表，`--unit undead_*` 选灵族、同框摆出该族）、`dark_race_materials.py --race undead`、`dark_race_textures.py --race undead`、`build_dark_parts.py`（单位前缀决定输出 `undead_refined/`）、`dark_refinement_contract_check --race undead`。运行时与 shader 复用 `dark_refined/shared`；`undead_refined/undead_parts.tres` 为灵族部件材质。`.gitignore` 为 `dark_refined/`、`undead_refined/` 加了例外，GitHub Desktop 才看得到这两个目录。
- 统一色板：`race_hue=0.253`（≈91°，小灵/毒灵/寄生灵火焰实测中位数），发光 `(0.42, 1.0, 0.14)`（红约为绿的 0.4，亮处不溢成黄）；暗金饰边与母灵芥末黄斗篷被拉向橄榄绿（母灵 0.95 并压暗）。
- 识别零件：毒灵右后胯发光毒液罐；寄生灵背上三颗半透明寄生囊和触须；刺灵背后五支投枪扇（枪头发光，高出兜帽）；自爆灵炸弹头顶引信火花、胸口毒核，黄色疙瘩发光；巨甲灵上背一排骨刺；母灵兜帽上一圈毒火角冠（圆心只取兜帽顶点，每根角用射线找该方向兜帽最外层表面再略微埋入）；小灵、飞灵只调材质。
- 母灵斗篷有朝内的三角面，单面剔除后露出描边黑壳：身体 shader 主体移入 `race_body.gdshaderinc`，新增 `dark_body_two_sided.gdshader`（cull_disabled）仅母灵使用。

| 单位 | 原常驻三角 | 新常驻三角 | 识别点 |
|---|---:|---:|---|
| 小灵 | 9,312 | 9,312 | 材质 |
| 毒灵 | 9,330 | 10,734 | 毒液罐 |
| 寄生灵 | 9,363 | 12,522 | 寄生囊 |
| 刺灵 | 9,246 | 10,146 | 投枪扇 |
| 飞灵 | 9,297 | 9,297 | 材质 |
| 自爆灵 | 9,252 | 10,938 | 引信、毒核、发光疙瘩 |
| 巨甲灵 | 9,090 | 10,980 | 背刺 |
| 母灵 | 9,270 | 11,160 | 毒火角冠、双面斗篷 |

### 11.3 本轮失败与修正

| 轮次 | 发现 | 修正 |
|---|---|---|
| Blender 初看 | 毒液罐、寄生囊太小，像饰物/蘑菇 | 放大 1.4–1.5 倍并上移 |
| 01 | 母灵背面黑三角（新旧都有）；投枪头、背刺发暗 | 双面 shader；`plate()` 用面序号区分顶面与侧墙（4 点轮廓的顶面曾被当侧墙涂边缘色，暗族法师符文同受影响已重建） |
| 02 | 寄生囊全亮成平面方块；母灵冠环像悬空黑条 | 囊体渐变（橄榄→玻璃→暗发光→亮尖）；去掉冠环 |
| 03 | 两侧角悬在兜帽外 | 每根角按自身方向的兜帽表面半径定位 |
| 设备测试（10-05） | 模拟器近景发现母灵角冠在各视角、各动作都离开兜帽，回看桌面最终采集同样如此，03 轮的修正并没有生效 | 原因：`y=1.5` 这一圈顶点混进了 rest 姿势里举起的法杖一侧（x<−0.4），圆心被拉偏约 0.28；兜帽在这一高度面数很少，按顶点估半径也不可靠。改为圆心只取兜帽（离头顶顶点水平 <0.45），`Body.outer_hit` 用 BVH 射线取该方向兜帽最外层表面再内收 0.025。暗族零件用新脚本重建后与已提交文件字节一致 |

审图教训：零件根部要逐个确认接触本体（正/背/侧 × 每个动作），尤其是正面看到的后排零件；按某一高度取整圈顶点前，先确认这一圈里没有武器、手臂等别的部件。

### 11.4 验证（本地）

- `dark_refinement_contract_check.tscn -- --race undead --require-integrated`：**686 项通过**（10-05 母灵角冠修正后重跑，灵族 686、暗族 710 仍全部通过）（原包装器运行文件哈希不变、骨架/片段一致、精修材质与零件、备战 idle-only、贴图 ≤1024 无 alpha；小灵/飞灵验证“无零件”）。同时重跑暗族 **710 项通过**（共用 shader 拆分与零件重建后）。
- 尺寸、材质完整性（报告列出 `undead_refined`）、根位移、连续播放检查通过；预算检查中灵族、暗族 0 项失败（现有 8 项失败来自上游新增的 `god_priestess_refined` 与 `crimson_race`）。
- 正式路线：PvP 第 6、12、18、21 回合，同一代码只切换 `race_units.json`：6 个上场灵族单位（毒灵、刺灵、飞灵、自爆灵、巨甲灵、母灵）加载精修场景、actor 契约完整、0 回退；模拟/终局/事件哈希新旧完全相同。小灵、寄生灵不在固定阵容中。正式路线截图早于母灵角冠修正（零件只影响画面，场景路径未变）。
- 桌面同条件：p95 7.58→7.41～8.33 ms；峰值 draw calls +8～10；纹理显存 +2.1 MB；>100 ms 长帧 1→1。

### 11.5 设备测试（Android 模拟器，2026-10-05）

本机无真机：`MSI App Player`（BlueStacks 4.280）因系统开启 Hyper-V 无法启动，改用 Android SDK 模拟器（Android 14 google_apis x86_64，WHPX，GPU 为主机 RTX 3070 Ti 经 GLES 翻译层）。按 §7.4 独立样板测三个代表：黑龙（常驻三角最多）、母灵（双面斗篷、角冠）、寄生灵（零件最多）；视口 1600×720，Compatibility，真实动画，原版/新版各 6 个、12 个。全部 `measurement_verified`，日志除模拟器专有的着色器缓存警告外无错误：

| 单位 | 数量 | p95 原→新 (ms) | draw calls 原→新 | 静态内存 原→新 (MB) | >100 ms 帧 |
|---|---|---|---|---|---|
| 黑龙 | 6 | 18.7 → 18.8 | 69 → 81 | 61.2 → 61.6 | 0 / 0 |
| 黑龙 | 12 | 18.5 → 19.2 | 81 → 105 | 65.2 → 65.9 | 0 / 0 |
| 母灵 | 6 | 18.6 → 18.3 | 69 → 81 | 58.2 → 58.5 | 0 / 0 |
| 母灵 | 12 | 18.6 → 18.3 | 81 → 105 | 60.1 → 60.8 | 0 / 0 |
| 寄生灵 | 6 | 18.4 → 18.4 | 69 → 81 | 59.0 → 59.3 | 0 / 0 |
| 寄生灵 | 12 | 18.3 → 18.5 | 81 → 105 | 61.7 → 62.4 | 0 / 0 |

模拟器锁 60 帧、GPU 是桌面显卡，帧时间只证明 Android/GLES/Compatibility 下安装、加载、渲染、零件与双面斗篷正常，**不代表手机性能**；draw calls（每个精修单位 +2）与静态内存（+0.3～0.7 MB）与平台无关。母灵数据为角冠修正（§11.3）后重新打包所测。真机与 iOS 仍未测试（Windows 无法构建 iOS），不得写“手机验收通过”。证据在两个交付目录的 `android-emulator/`。
