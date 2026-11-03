# GLory 构建与资源交付约定

## 测试服 / 正式服地址

| 用途 | 测试服 | 正式服 |
|---|---|---|
| IP | `34.124.141.90` | `35.247.132.13` |
| 账号接口 | `https://glorytd-api.duckdns.org` | `https://glorytd-prod-api.duckdns.org` |
| 战斗（UDP + DTLS） | `glorytd-battle.duckdns.org:8080` | `glorytd-prod-battle.duckdns.org:8080` |
| 语音 | `wss://glorytd-voice.duckdns.org` | `wss://glorytd-prod-voice.duckdns.org` |

- 客户端源码默认值是测试服（`scripts/account/AccountConfig.gd` 的 `DEFAULT_BACKEND_URL`、`scripts/multiplayer/NetworkConfig.gd` 的 `SERVER_HOST`）。语音地址由服务器下发（战斗服务器和账号服务器各自的 LiveKit 配置里的 `client_url`），客户端不写死。
- 战斗链路的 DTLS 证书两边不同：客户端 `scripts/multiplayer/NetTLSCert.gd` 里是测试服那张（SHA-256 `F7:73:C1:A5:…:A4:9C:25:0D`），正式服是 2026-10-31 新生成的（SHA-256 `DE:B1:9B:3E:…:0E:CA:53:54`，以服务器上 `~/Glory/keys/dtls_cert.pem` 为准）。切正式服只改域名、不换证书，会卡在连接中直到超时。

## APK / IPA 必须使用精简打包入口

今后构建 APK 和 IPA，必须使用本仓库 `tools/workspace/build_apk.sh` 和
`tools/workspace/build_ipa.sh`。外层工作区 `GLory/tools` 是该目录的符号链接，
在外层工作区运行时分别使用 `./tools/build_apk.sh`、`./tools/build_ipa.sh`。
不要另写临时打包脚本，不要绕过入口直接从编辑器导出交付包。

- APK 默认精简 Release，使用已有发布密钥，保留 arm64/armv7；仅排查问题时显式使用 `--debug`。
- IPA 使用精简 Release；TestFlight 指定 `--method app-store`，已登记设备安装指定 `--method ad-hoc`。
- 两个入口都会在隔离 stage 中按当前代码、场景依赖和动态资源声明剔除无引用资源，并输出 `slim-resources.json`。
- 不删除原始资源，不降低纹理质量，不擅自减少设备架构或语音能力。动态路径必须保守保留；新增动态加载机制时同步更新依赖扫描和测试。
- 保留本地修复。同步仅在明确需要时使用 APK 的 `--sync` 或 IPA 的 `--update`；不得 reset/stash/覆盖用户未提交修改。
- 需要 patch 的客户端必须传 `--patch-config <配置 JSON>`。新客户端基线使用独立 `base_id`；必须保留该次精简 stage 导出的 `base.zip`、`base.export.json` 和构建结果，不能以全量资源基线替代。
- 使用 `--result-file <JSON>` 获取本次准确产物。APK 可用 `--version`、`--version-code`；IPA 可用 `--version`、`--build-number`。
- 交付前检查签名、版本、包内依赖和补丁基线一致性。构建成功不代表上传、TestFlight 处理、测试组分配或真机验收成功；分别报告。
- 构建入口不会自动上传、发布或改写在线补丁基线。只有得到相关任务授权后才执行这些步骤。

详见 `tools/workspace/SLIM_BUILD.md`。
