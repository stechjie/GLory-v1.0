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

## 产物与补丁

- APK：`build/apk/`；结果 `build/latest-apk.json`。
- IPA：`build/ipa/`；结果 `build/latest-ipa-app-store.json` 或 `build/latest-ipa-ad-hoc.json`。
- 每次日志目录有 `slim-resources.json`（剔除清单、动态保留记录），结果 JSON 含精简和压缩信息。
- `--patch-config` 启用更新器并从同一精简 stage 保留 `base.zip` / `base.export.json`。新的内容布局需要独立客户端基线，不能覆盖已安装客户端的基线记录。
- 两个入口只生成本地产物。Drive/TestFlight 上传、更新二维码、后台注册基线和发布 patch 属于后续明确授权的发布步骤。
- 新增动态资源加载形式时，先更新扫描器/声明并验证导出包能加载该资源，再交付。仍需真机验证下载、更新和游戏流程。

## 回归验证

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
