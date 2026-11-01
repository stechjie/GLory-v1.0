# GLory 构建与资源交付约定

## 云服务器环境归属

- 测试服固定使用 Google Cloud 项目 `project-60c72d94-b558-4e4f-992`：
  https://ssh.cloud.google.com/v2/ssh/projects/project-60c72d94-b558-4e4f-992/
- 正式服（审核服）固定使用 Google Cloud 项目 `project-60d2cb8c-3b40-4f95-a67`：
  https://console.cloud.google.com/compute/instances?project=project-60d2cb8c-3b40-4f95-a67
- 发布、部署和支付配置前，实际核对项目、实例、域名、数据库与运行环境；不得沿用旧文档的“正式服”称呼来判断环境。
- Google Play 正式包连接正式服（审核服）；测试包连接测试服。账号接口、战斗连接、语音、补丁检查及通知回调须核对环境一致性，不能只修改启动器地址。
- 更新两套服务器时分别核验、备份和验收，保留各自配置与凭证，不把凭证写入仓库、日志或打包产物。
- 重启前检查在线玩家；有玩家在线时等待，除非用户明确授权中断。构建、部署、健康检查与真机沙盒支付验收分别记录。

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
