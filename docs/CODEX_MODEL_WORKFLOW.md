# GLory：给 Codex 执行的 3D 角色模型精修工作流

把本文件和完整项目交给 Codex，指定角色，即可开展诊断、制作、接入和测试。目标是**角色更容易区分、结构和材质更精美、符合种族与职业设定，并在真实游戏和手机上成立**。允许精修原模型，也允许制作新资源替换；面数增加、工具安装或代码检查通过都不等于目标完成。

本文是普通 Markdown 执行说明，不需要安装成 skill。项目入口与研究来源复核日期为 **2026-10-03**；后续使用必须以当前代码、实际资源和工具版本为准。第 9 节记录首个样板，不能当作其他角色已验收。

## 1. 怎样交接与执行

同事需要本 MD、同版本 `GLory-v1.0` 源码及角色实际引用的模型、贴图、动作资源。先按 `docs/WORKSPACE-LAYOUT.md` 核对目录；部分美术另由资源包分发，只有 Git clone 不一定齐全。缺少资源时列出具体路径，从已授权交付源补齐，保留本地较新文件；不使用占位模型完成验收。

最低环境是项目匹配的 Godot；制作可编辑模型使用 Blender，构建工具使用 Python 3.10+；Android 测试还需要匹配的导出模板、SDK、JDK、ADB。复用已有环境，先看目标脚本 `--help` 和 `--check`，不为单个模型重装整个工具链。

在项目聊天中粘贴，至少填写“对象”：

```text
阅读并执行 docs/CODEX_MODEL_WORKFLOW.md。
对象：<角色名称 / unit_id，例如 god_guard 光之卫士>
问题：<辨识度低、造型粗糙、材质糊；可以补参考图>
方向：<保持种族与角色设定；或明确指定风格/配色>
范围：<单个角色；或一组角色逐个验收>
设备：<当前连接手机；或指定设备>
允许精修原资源或新增替换，保留回退版本，先使用免费本地工具。
本次允许安装必要免费工具并在指定手机测试；不改变玩法、动作时序和挂点契约。
请先加载真实模型和同族角色比较，再制作、实际预览、接入并测量。
不满意就依据画面指出问题、修改并复验。交付可编辑源、可重跑脚本、前后对比和测试证据。
不要自动提交、推送、发布、同步远端或上传私有素材到第三方服务。
```

批量任务建立 `unit_id / 设定 / 原场景 / 候选资源 / 缺陷 / 状态 / 证据` 清单。每个角色独立验收；共同族色不是让全族共享同一轮廓。

## 2. 先锁定角色与项目契约

### 2.1 工作区与执行范围

1. 找到同时包含 `.git`、`project.godot`、`data/`、`assets/` 的根目录。本机为 `/Volumes/repository/github/GLory/GLory-v1.0`，外层是交付容器，同事机器路径可以不同。
2. 读取适用 `AGENTS.md`，记录 `git rev-parse HEAD`、`git status --short`、`git diff --stat`。保留已有未提交改动，不全局 reset/clean，不覆盖其他角色或资源。
3. 核对 Godot `--version`、实际渲染器、导出预设、模型和动作源是否齐全。项目声明 Godot 4.7；以手机实际渲染器和 3D 视口尺寸验收，不以桌面配置推断。
4. 既有授权覆盖必要的本地制作、免费工具安装与指定手机测试时直接推进。新工具先核对来源、许可和本机支持；付费服务、第三方上传、远端发布不由本 MD 自动授权。

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

再把目标与至少两个最容易混淆的同族角色放在同一画面：先看无名字的轮廓/灰度，再看正常材质。必要时给全族做联系表，记录身宽、头肩形状、武器、背部和站姿差异。辨识点必须在游戏实际显示尺寸下可见。

### 3.2 分开诊断，不先加面

| 现象 | 需要检查 | 对应改进 |
|---|---|---|
| 全族像同一个人 | 小尺寸剪影、体型、器具、主次形状 | 先改比例和 2～3 个职业识别部件，颜色只作辅助 |
| 身体像圆柱或玩具 | 甲片厚度、倒角、关节和软硬材质边界 | 调整真实几何与部件层次，不只加发光线 |
| 表面糊或缺细节 | 源图与运行贴图尺寸、UV 利用率、纹理过滤、压缩 | 局部调整导入/UV/纹理，不全局提高全部贴图 |
| 有纹理却显平 | 实际 Shader 是否使用法线/粗糙度/高光，法线方向 | 调整角色专属材质；不要为一个角色改坏共享 Shader |
| 曲面明显多边形 | 近景与战斗距离轮廓、法线断裂、实际三角数 | 修法线或有选择加密曲面/倒角，以可见收益决定 |
| 动起来穿插、拉长 | 蒙皮权重、骨骼挂接、动作极限、运行根位移 | 修权重和部件位置，静态 AABB 不能证明动画包覆正确 |

盘点 mesh/surface 数、顶点与三角面数、骨架与骨数、材质、纹理运行尺寸和 draw calls。UV 缝或硬边会拆顶点，顶点数不等于三角面数；文件体积也不等于显存。给出 2～4 项有截图支持的主要缺陷，再选择制作路线。

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

引入时记录 URL、作者、版本/commit、许可原文、安装路径和用途；复制代码或素材时保留要求的版权声明，素材独立许可单独核对。不要把代码 MIT 等同于所有云服务和资产免费。

本次可用的官方 LTS 候选为 [Blender 4.5.14 macOS ARM64](https://download.blender.org/release/Blender4.5/blender-4.5.14-macos-arm64.dmg)，[官方校验文件](https://download.blender.org/release/Blender4.5/blender-4.5.14.sha256)中 SHA256 为 `65134d9b07b20e2fa8d3c9e44f6f44ffb5c9774dd521b95f50387310241ca170`。这是本次核实版本，后续选择版本时重新检查官方来源。

## 5. 制作：结构先行，细节分层

1. **比例和主轮廓。** 先完成可辨识的黑色剪影，落实职业识别点。坦克可用坚实胸肩、稳定下肢与防御器具体现定位；具体设计必须与现有角色动作及设定一致。
2. **中尺度部件。** 处理甲片叠层、肩/胸/腰的承接、器具厚度和倒角。用几何表现会改变轮廓和遮挡的结构。配件不能悬浮、过度对称复制或覆盖所有关节。
3. **表面细节。** 用材质分区、粗糙度、法线和适度雕纹建立白色甲壳、金属、布料的区别。主识别线在小尺寸下仍要清楚，微细噪声不能导致手机闪烁。提高分辨率前确认 UV 与导入限制确实是瓶颈。
4. **控制光照。** 保持基线灯光，使用局部材质实例/专属 Shader。高光要显结构，发光不能把形体洗成纯白。不得用更强灯光、景深、Bloom 或特效遮盖几何问题。
5. **必要时重拓扑/烘焙。** 先保存高模与原始绑定版本；高模细节烘焙至游戏网格的法线/粗糙度，轮廓细节保留几何。检查 UV 接缝、cage、法线方向、mipmap 边距。自动重网格后重新转移和检查权重，不假设动画仍正确。
6. **保存可编辑源。** 保留 `.blend`、制作脚本/参数、原资源引用、GLB、材质与必要贴图。仅截图或渲染视频不构成模型交付；仅挂配件也不能自动证明主体比例和材质已改善。

每轮只解决已记录的主要缺陷，重拍同条件对比。若主轮廓还不清楚，先修轮廓；若真实 Shader 丢失细节，先修材质路线。禁止通过无目的 subdivision、随机切割或装饰堆叠追求“更多面”。

[Blender 重网格说明](https://docs.blender.org/manual/en/4.5/modeling/meshes/retopology.html)说明其主要改变网格密度和拓扑；[烘焙说明](https://docs.blender.org/UATEST/manual/en/4.5/render/cycles/baking.html)说明高低模法线烘焙条件。这些工具能力不能替代角色设计。

## 6. 保留动画与正式接入

- 优先保留现有骨架、骨名/父子关系、绑定姿势和动作库；新增刚性护甲/器具绑定适当骨骼，软部件需要正确权重。检查是否给原有动画层重复套变换。
- 比对所有已有动作的名字、长度、循环、轨道目标、根位移与攻击触发点。至少真实播放 idle/run/attack；受击/死亡有专用动作时也测，没有时保持既有处理，不为验收伪造新动作。
- 保留 `play_idle()`、`play_run()`、`play_attack()` 等当前包装接口。不要照搬外部 skill 将动作改名 `AN_*`；不要用静态姿势或程序摆动替换原有蒙皮动作。
- 比较身体与配件在跑步、抬手、攻击末端的相对位置，检查漂浮、穿插、脚滑、断层及镜像朝向。保留脚底/施法/命中挂点与技能包覆；修模型不应让此前护盾和武器落在错误位置。
- 导出时验证绑定姿势、三角化、法线/切线、材质、纹理和动画。只应用适当的几何修改器，不把 Armature 当静态网格烘掉。[Godot 导出约定](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_3d_scenes/model_export_considerations.html)以 +Z 为角色正面；项目现有旋转补偿仍以运行结果为准。
- [Godot 推荐 glTF/GLB](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_3d_scenes/available_formats.html)。OBJ 不携带骨架/动画；`.blend` 直接导入依赖本机 Blender。团队交付优先保留 blend 制作源，同时导出独立运行 GLB，避免手机样板依赖制作软件。Blender 批处理使用 `--python-exit-code 1`，同时确认导出文件存在、体积与内容正确；进程返回 0 不能单独证明导出完成。版本变化时先检查操作符参数，本轮 4.5 使用 `export_vertex_color`，不接受旧 `export_colors` 参数。
- 可保留原始包装场景引用，在新包装层使用精修 mesh/材质；也可新建候选资源后仅切换目标的模型视觉映射。记录 `原路径 → 新路径 → 正式调用`，不能只修改没有被调用的预览。
- 修改数据表时严格限制为本次需要的视觉字段。`UnitVisualResolver.VISUAL_FIELDS` 是代码实现，不是任意改值许可；不得顺便改 `tier`、费用、伤害、血量、范围、移动/攻击速度、技能目标或回放规则。攻击同步与挂点契约本次保持不变。
- 材质不要污染共享资源，原新模型不要重复叠加显示。正式战斗与备战/图鉴若使用同一映射，分别确认显示正确；旧版本保留在 Git 基线或明确的参考目录中。

## 7. 验证画面、路由与手机成本

### 7.1 技术检查覆盖正确对象

先读现有工具覆盖范围，再选相关检查：`tools/model_material_integrity_check.gd`、`tools/model_bounds_check.gd`、`tools/model_asset_budget_check.gd`、`tools/model_action_contract_report.gd`、`tools/model_action_playback_continuity_check.gd`、`tools/model_root_motion_inventory_check.gd`。复用 `tools/model_visual_matrix_capture.gd` 做适当画面采集。检查导入错误和 `git diff --check`。

刚性附件跟骨运动正确也不证明它不穿模或好看。新增甲片须与原身体的曲率、倒角、金属明暗及细节密度协调；本轮四件附件的 184 项技术断言通过，但箱形肩甲和棕色金属仍被视觉审查淘汰。

技术通过只证明其断言覆盖的资源/契约；无关检查全绿、像素有变化、骨骼数量相同都不证明美观或动画正确。

当前工具有明确覆盖边界：`model_bounds_check` 使用 `load_idle_only`，不证明 run/attack 的动态轮廓；`model_visual_matrix_capture` 的矩阵是 idle/attack/hit/death，缺 run，且其配置检查要求 Mobile，不能代替 Compatibility 真机结果；`model_action_playback_continuity_check` 只选中配置了 `model_in_place_actions` 包含 run 的对象，目标未配置时可能被跳过。始终检查报告实际枚举了本次 unit_id 和动作，空覆盖不能过关。

### 7.2 循环预览与视觉判定

专用入口为 `res://scenes/debug/ModelRefinementPreview.tscn`。执行前确认文件与依赖存在，再在 Godot 编辑器打开运行；不要修改项目正式主场景来启动样板。预览提供原/新模型、近景/战斗距离与真实动作观察；截帧时不用 `--headless`。

**当前提供的预览和下方命令是 `god_guard` 样板。** 它的原/新路径、同族对照和标题有角色配置，不会因聊天中写“神侍”就自动换模型。测试其他角色前，创建该角色的预览并明确配置目标 ID、旧/新路径、缩放、动作、朝向及对照角色；构建时必须同时传 `--unit-id`、`--preview`、`--old-model`、`--new-model`，runner 也要传同一个 `--unit-id`，完整命令见 7.4。先检查日志、画面标题和加载资源都对应目标，再开始手机矩阵。默认样板支持 `--unit god_guard` 核验，传入其他 ID 会拒绝执行，防止成功测完错误对象。新预览须保留同样的身份校验：性能请求必须包含 `unit_id`、`old_model_path`、`new_model_path`，三项与预览配置及非空 `model_build_info.json` 一致；构建指纹也必须非空。纯交互预览不要求性能请求或构建信息。

```bash
MODEL_PROJECT="/本机路径/GLory-v1.0"
MODEL_GODOT="/本机路径/Godot可执行文件"
"$MODEL_GODOT" --editor --path "$MODEL_PROJECT" \
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

### 7.4 独立 Android 样板

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
- 最终运行统计：**7213 顶点 / 8538 三角面 / 5 surfaces / 3 个唯一材质（含身体描边）/ 最大纹理 1024**。原版 3018 面，增长主要用于盾牌弧面和倒角，属于约 2.83 倍三角数的单角色试点，不能直接全族照搬；是否保留由同条件手机结果决定。
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

制作源和证据位于项目外层 `delivery/model-workflow-20261003/`。DCC 使用已核验的 Blender 4.5.14 LTS，`source/guardian-original.glb` 和 `source/guardian-original-rig.json` 是从实际原场景导出的参考及坐标契约。生成脚本为 `tools/model_refinement/build_guardian_armor.py`；输出包含可编辑 blend、GLB 与部件清单。

最终可直接打开的是 `source/guardian_refined_editable.blend`：22 个新增部件已在 Blender 中真正附骨，原纹理已打包。`source/parent_guardian_editable_parts.py` 是不导出 runtime 的源文件后处理；它验证静止变换、四骨分别旋转 17° 的跟随、还原及保存后重开，报告 `source/guardian_editable_check.json` 全部通过。静止矩阵最大误差约 `2.09e-7`；原动作关键帧和原几何不变。Godot 有 83 个骨节点，导出的 GLB skin 与 Blender data.bones 为 82，`RL_BoneRoot` 作为根对象另计；这是格式表示差异，不能误报丢骨。Blender 材质用于编辑参考，最终画面仍以 Godot 专属 shader 和运行 1024 纹理验证。

```bash
MODEL_BLENDER="/本机路径/Blender可执行文件"
mkdir -p "$MODEL_OUT/audit" "$MODEL_OUT/source"
# 将仓库内版本固定的源文件工具复制到交付目录，再操作交付源文件：
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

手工编辑使用另一条入口：上面的生成器从原 GLB 和脚本参数重新建附件，**不会读取最终 editable blend 的手工改动**。在 Blender 中修改 `.blend` 后，用已交付的 `source/export_guardian_editable_parts.py` 导出附件，不能直接把整个场景导出后覆盖游戏 GLB。此工具使用原 Godot rest JSON 转换坐标，按四个 `bone_name` 合并，保留顶点 `Color`、法线和一个共享材质，排除原身体、骨架与动画；颜色应修改 `Color` 属性，单改 Blender 材质基础色不会改变运行专属 shader。

```bash
"$MODEL_BLENDER" --background --python-exit-code 1 \
  --python "$MODEL_OUT/source/export_guardian_editable_parts.py" -- \
  --source "$MODEL_OUT/source/guardian_refined_editable.blend" \
  --rig-json "$MODEL_OUT/source/guardian-original-rig.json" \
  --output "$MODEL_OUT/source/manual-edited-armor.glb" \
  --manifest "$MODEL_OUT/source/manual-edited-manifest.json"
```

先审查导出，再把该 GLB 替换角色目录的 `guardian_armor.glb`、重新导入，执行资源契约、多角度动作检查和手机重新构建。手改后不能继续使用修改前的性能报告。未手改源的回导已完成隔离 Godot 检查：**37 项通过**，四组附件实际附骨后的逐三角世界几何、绕序、顶点色、法线、AABB 与锁定 runtime 一致，最大误差 0；报告为 `source/editable-export-equivalence.json`。该报告证明无损回导，不自动证明后续手工编辑美观。

同样采集 `--view side`、`--view back`、不带 `--close` 的 `--view battle`，以及 `--compare`、`--lineup`。这些实际渲染命令会自动保存四帧及准确动作时间后退出；`--smoke` 只检查加载和动作，不产生视觉通过结论。

### 9.4 正式页面和手机证据

正式页面采集须使用隔离工程与独立用户目录，避免修改操作者存档。`model_refinement_prep_capture.gd` 验证正式 PrepScreen 路由、棋盘/候补不同星级与脚底；`--validate-fixture` 可预先检查阵位。按正式 Prep 的 `prep_visual_root` 元信息定位实例，记录实际路径。固定阵容要检查自动合成：本轮两个 1 星同名卫士进备战后合成，测试错误地等一个已被合并的候补；改为 1/2/4 星并验证合成阈值、实际星级和逐节点状态后通过。等待超时须输出哪个槽位缺失/隐藏/未居中，不能只给笼统失败。

完整手机战斗使用独立包 `com.glory.modelbattlepilot`，真实调用 `FixedBattleFixture → BattleSimulator → GameState.pending_battle_package → BattleScreen`。它是本地固定回放，保留正式单位/UI/模型/特效负载，关闭不需的网络与语音权限；不证明线上联机行为。

```bash
python3 tools/build_model_battle_pilot.py --godot "$MODEL_GODOT" \
  --out "$MODEL_OUT/android-battle-build" \
  --expected-model res://assets/models/units/god_guard_refined/god_guard_refined.tscn --build
python3 tools/run_model_battle_pilot.py --serial "$MODEL_SERIAL" \
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
