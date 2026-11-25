# 精简 APK / IPA

在外层 `GLory` 工作区使用以下两个固定入口。APK 默认签名 Release；IPA 为 Release，默认 ad-hoc。

```bash
./tools/build_apk.sh --check
./tools/build_ipa.sh --check --method app-store

./tools/build_apk.sh --project GLory-v1.0 --version 0.0.22 --version-code 34 \
  --patch-config /path/to/new-base.json --result-file /path/to/apk-result.json
./tools/build_ipa.sh --project GLory-v1.0 --method app-store --version 0.0.22 \
  --patch-config /path/to/new-base.json --result-file /path/to/ipa-result.json
```

示例版本号不是下次发布号；先核对已交付版本。IPA build number 缺省自动递增。签名从本机现有密钥库/钥匙串取得，不把密码放入命令、Git 或日志。

2026-11-14 起，IPA 默认使用外层工作区 `ios-signing-20260913/ios_distribution/20261114-apple-signin/` 中的 `Glory_AppStore_2026.mobileprovision` 和 `Glory_AdHoc_2026.mobileprovision`。两份文件已启用 Apple 登录、匹配现有分发证书；原始下载文件已移出 Downloads。旧描述文件保留在原签名目录供回溯，不作为默认输入。新文件权限为仅本机用户读写；描述文件不放入 Git。

只需本地打包时不加同步参数；需要同步才加 APK `--sync` 或 IPA `--update`。本地修改保留，Git 分歧需先处理。

## 精简策略

- 先合并代码和资源到隔离 stage，复用 Godot 导入缓存，验证模型最终材质和动作。
- `glory_slim.py` 从当前脚本、运行时数据、场景、项目入口及 Godot 资源依赖建立引用关系。
- 保留动态资源清单和动态路径前缀覆盖的文件；无法解析的 UID 依赖停止构建。
- 只把无引用美术资源加入生成的导出排除规则，不删除源文件，不降低画质，不删除 ABI。
- 排除工具、部署、备份、预览等非运行内容。美术库存 JSON 不作为“所有库存都必需”的依据。
- APK 无损压缩 assets 和 native 库，启用 Android native 库解压，执行 16 KiB ZIP 对齐并用现有发布密钥重新签名。
- IPA 只调整外层 ZIP 压缩级别；应用内文件和签名内容不变，再执行 codesign、版本、语音依赖及 PCK 身份校验。

APK 下载文件更小不等于安装占用同幅度下降：native 库安装时会被解压。保留 armv7 和 arm64，避免为了体积缩小设备覆盖范围。

## iOS 商店与桌面名称

iOS 的正式名称固定为 `GLory: Auto Chess & Team PvP`，与本轮 App Store Connect 英文名称完全一致。马来文 `GLory Catur Auto PvP 3v3`、印尼文 `GLory Catur Otomatis 3v3` 和中文 `GLory 自走棋：3v3组队对战` 保留同一品牌与玩法定位。
源码通过 `config/name.ios` 声明 iOS 名称；IPA 入口还会在隔离 stage 中统一
`config/name` 并去除过时的名称覆盖，避免导出器回退到 `Glory Beta 0.04`。
桌面及服务器仍使用原工程名来定位已有存档和服务密钥，不做全平台工程目录迁移。

交付前读取**最终签名 IPA** 的 `CFBundleDisplayName`，并检查各语言的
`InfoPlist.strings` 覆盖；名称缺失或不一致时构建失败。结果中记录
`validation.display_name` 与 `validation.localized_display_name_checks`。
这类名称属于安装包元数据，需要新 build，不能靠资源 patch 修改桌面图标名称。
iOS 的 `export_patch.py` 同步应用同一名称规则，使手工及 nightly 新建的 stage
与新 IPA 的不可变工程配置一致；旧基线不改写。

## iOS Game Mode

IPA 入口为后续导出写入 `LSSupportsGameMode=true`，同时保留 `GCSupportsGameMode=true` 兼容 iOS 18.0–18.5。前者从 iOS 18.6 起可用，旧键从 iOS 18.6 起弃用。两个声明都只是让系统识别 Game Mode 支持，用户仍可在控制中心的 Game Overlay 中关闭该模式。

交付校验读取最终 IPA 内的 `Info.plist`，要求两个键均为布尔值 `true`；成功结果包含 `validation.game_mode_support=true`。源码或预设已配置不等于当前手机已启用，需要重新打包安装后检查控制中心。

Game Mode 为前台游戏优化系统资源调度，不能保证切到桌面或锁屏后游戏持续运行、网络不断线。一般应用进入后台后仍会被 iOS 挂起；后台挂机进度应由服务器保存和推进，回到前台后验证连接并恢复状态。本配置不声明额外后台运行模式。

依据：[Apple Game Mode](https://support.apple.com/en-ie/105118)、[LSSupportsGameMode](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode)、[后台执行模式](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)。

## 产物与补丁

- APK：`build/apk/`；结果 `build/latest-apk.json`。
- IPA：`build/ipa/`；结果 `build/latest-ipa-app-store.json` 或 `build/latest-ipa-ad-hoc.json`。
- 每次日志目录有 `slim-resources.json`（剔除清单、动态保留记录），结果 JSON 含精简和压缩信息。
- `--patch-config` 启用更新器并从同一精简 stage 保留 `base.zip` / `base.export.json`。新的内容布局需要独立客户端基线，不能覆盖已安装客户端的基线记录。
- 两个入口只生成本地产物。Drive/TestFlight 上传、更新二维码、后台注册基线和发布 patch 属于后续明确授权的发布步骤。
- 新增动态资源加载形式时，先更新扫描器/声明并验证导出包能加载该资源，再交付。仍需真机验证下载、更新和游戏流程。

## 回归验证

### Patch 默认精简

手工补丁和 `nightly_patch.sh` 统一调用 `export_patch.py`，在 Godot 导入后、导出资源 ZIP 前重新执行同一依赖扫描。没有全量回退开关；扫描失败则停止构建。每个平台输出 `slim-resources.json` 和 `slim-patch-compatibility.json`，nightly 状态记录这两个报告路径。

重复使用 stage 时会撤销上次扫描生成的排除项，再按最新引用计算；原有手工排除规则保留。保留 stage 时也保留 `.glory-slim-filters.json`；新基线清单同时记录自动排除源路径。

旧基线若缺少自动排除记录，仍保留原来的严格预设校验；发现已被排除的资源重新成为运行依赖时停止构建，需恢复原始精简记录或重新制作全量基线，不能静默导出缺失资源。

补丁不能从已安装原包中删除资源。对本次扫描确认无引用、但原包已经带有的资源，仅在差异比较 ZIP 中继承原始字节，因此不进入新补丁；对应导入映射和导入产物同样处理。其他删除、引擎／原生库／启动器变化继续拒绝构建，要求重新出全量包。旧基线 ZIP 不会被修改。

```bash
python3 -m unittest discover -s tools -p test_glory_slim.py -v
python3 -m unittest discover -s tools -p test_glory_build.py -q
python3 -m unittest discover -s tools -p test_glory_ios_build.py -q
```

修改扫描器后需重新构建并校验实际包内容；不能只检查源目录资源存在。AAB 是 Google Play 的独立产物，仍使用 `build_aab.sh`，本入口约定不将 APK 当作 AAB。

AAB 同样在隔离 stage 中应用上述依赖精简策略，保留全部设备架构和语音依赖。可显式指定版本并获取本次签名产物，避免上传过期文件：

```bash
./tools/build_aab.sh --version 1.0.0 --version-code 44 --result-file /path/to/aab-result.json
```

版本号仅为示例，实际构建前须核对 Play Console 的版本代码。结果包含签名文件路径、哈希、精简清单和验证报告；构建不自动上传或提交审核。

## 2026-10-12 验证结果

同一份最新代码/资源，APK 606,336,442 → 547,916,446 字节（减少 9.63%），IPA 572,237,271 → 513,969,651 字节（减少 10.18%）。排除 205 个无引用美术源路径；对应导出内容体积以最终包为准。

Android 4,831 个、iOS 4,833 个基线文件逐项匹配实际包；各平台加载 2,361 个资源、编译 26 个服务脚本，验证 8 个精修模型的三个动作。iOS 语音为设备原生库，macOS 无头验证不覆盖它；IPA 签名和原生依赖结构已检查，仍需真机验收。47 项相关脚本测试通过。

此次为本地构建验证，产物使用独立验证 base_id，未注册线上基线、未上传或替换已发布包。工作区证据见 `delivery/slim-20261012/verification.json`。

### Google Play 服务器选择

Google Play 正式／审核包使用 `./tools/build_aab.sh --server-environment prod`；
测试服包使用 `--server-environment test`。APK 入口也支持同名选项。
选择只改隔离 stage，不改源码默认值；AAB 构建记录会保留目标环境。
正式服账号为 `https://api.gogoglory.com`，战斗为
`battle.gogoglory.com:8080`（UDP + DTLS），语音由正式服下发
`wss://voice.gogoglory.com`（当前环境约定见 AGENTS.md）。使用 `--patch-config` 时账号与补丁
接口必须匹配；新版本保留独立基线。

iOS 正式候选包也显式指定 `./tools/build_ipa.sh --method app-store --server-environment prod`。
TestFlight 与后续 App Store 提审使用同一候选包；`--patch-config` 的 `backend_url`
必须匹配所选环境，否则停止构建。构建记录的 `server_target` 保留环境与实际端点。

## iOS 27 SDK 与 iPhone Duo

构建统一要求 **Xcode 27.1 / iOS SDK 27.1 或更高版本**，当前验收工具链是 Xcode 27.2 (27B52)、iPhoneOS SDK 27.2 (24B8118)。这高于 Apple 从 2027 年 4 月起上传要求的 iOS 27 SDK，并覆盖 Duo 的 27.1 布局 API；最低部署版本继续是 **iOS 15.0**。

`build_ipa.sh` 保留调用者显式设置的 `DEVELOPER_DIR`；也可传 `--developer-dir /Applications/Xcode.app/Contents/Developer`。工具链低于要求时，在签名、快照和打包之前失败。最终 IPA 从主程序 `LC_BUILD_VERSION` 读取真实 SDK，再与 `DTSDKName`、`DTSDKBuild`、`DTXcodeBuild` 及本次选定工具链交叉核验。不会通过改写 plist 版本号使旧二进制看起来合规。构建身份记录 `toolchain`，结果中的 `validation.apple_toolchain` 保存已验证 SDK、Xcode build 和最低系统版本。

窗口配置保留旧系统的 `UIRequiresFullScreen=true`，添加字符串 `UIRequiresFullScreenIgnoredStartingWithVersion="27"`；最终包还必须具备 launch screen 与 scene lifecycle 配置。旧全屏键已经由 Godot 模板生成，额外 plist 内容只添加版本忽略键，避免重复键。配置校验只证明声明正确，Duo 开合布局、触控和输入仍需运行验证。

引擎模板由 `build_ios_audio_template.py` 同时应用 `godot-4.7-ios-audio-recovery.patch` 和 `godot-4.7-ios-duo-layout.patch`，通过显式真实 SDK 路径编译 GL Compatibility arm64 库，不改画质和其他平台渲染器。模板 `glory-engine.json` 记录两个补丁的指纹与工具链；IPA 入口拒绝旧的未适配模板。模板构建默认输出到 `build/ios-duo-templates/4.7.stable`；IPA 入口按显式 `--templates`、`GODOT_TEMPLATES`、新 Duo 模板、旧音频模板、stock 模板的顺序查找，再校验补丁和 SDK 指纹。若源码来自无 Git 元数据的解压归档，manifest 明确记录 `source_commit_verification=source_archive_no_git_head`，不声称已读取不存在的 Git HEAD。

隔离 worktree 构建须同时指定源工程与外层工作区。`GLORY_WORKSPACE` 决定资源、签名、锁、日志和产物根目录，`--project` 决定源码；不要把它指向源码自身：

```bash
GLORY_WORKSPACE=/Volumes/repository/github/GLory \
  /path/to/worktree/tools/workspace/build_ipa.sh \
  --project /path/to/worktree --check --method app-store \
  --developer-dir /Applications/Xcode.app/Contents/Developer
```

实际构建仍通过同一入口，添加本次独立的 `--patch-config`、`--result-file`、`--server-environment prod` 和已决定的营销版本。不要复用已有客户端的 `base_id`。

Apple 依据：[上传要求](https://developer.apple.com/news/?id=k1mtkt1k)、[Duo 准备](https://developer.apple.com/iphone-duo/prepare/)、[窗口兼容模式迁移](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key)。

### 本地 Simulator QA app

`build_ios_simulator_app.py` 从 canonical IPA 流程生成的 Xcode 工程创建独立 APFS 克隆，仅替换真实 Simulator 引擎与原生 frameworks。调用时指定 `--xcode-export`、`--work-dir`、`--engine-library`、`--native-frameworks`，可用 `--pck` 提供保留生产控件的 QA 资源包。输出固定为独立 bundle `com.superforge.glory.duoqa`，默认只并行 2 个 Xcode 任务，并只做本地 ad-hoc 签名；不会安装、上传或替换正式包。

每次在 `--work-dir/runs/<时间戳>/` 保留 `inputs.json`、`xcodebuild.log`、`result.json` 和实际 app，成功后更新 `latest-result.json`。输入原工程、引擎、三份 native frameworks、PCK 与成品主程序均记录 SHA-256。验证 Simulator 的 arm64 平台、实际 SDK 与 Duo 实现标记。供应商依赖可保留其真实旧 SDK，主程序必须由当前 SDK 编译。

Simulator app 是独立测试目标：QA PCK 或独立 bundle 下的结果不能替代正式账号登录、Apple 支付、物理 GPU 性能、实体 Duo 或 TestFlight 验收。实际运行需记录使用的 PCK 与场景范围。生产交付仍必须通过 `build_ipa.sh`。
