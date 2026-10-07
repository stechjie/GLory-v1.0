# 工作区构建与同步工具

唯一源码位于仓库 `tools/workspace`，工作区 `GLory/tools` 是指向此目录的快捷链接。推荐目录：`GLory/GLory-v1.0`。从任意当前目录调用均可；双击本目录 `.command` 即可同步或构建。

- `sync_res.sh`：下载 Drive 资源到工作区 `res/assets`，校验同名文件与本地版本，保留本地较新资源。
- `build_apk.sh --sync`：同步后合并资源，在 `build/android-work` 隔离构建。
- `build_ipa.sh --update`：同步后构建 IPA；签名配置仍使用本机私有目录。
- `release_testflight.sh`：使用本机账号配置提交内部测试；测试说明读取工作区 `docs/TestFlight测试内容.txt`。

新机器在工作区执行：`ln -s GLory-v1.0/tools/workspace tools`。签名文件、密钥、构建缓存及本地测试说明不提交 Git。Python 需要 3.10+；资源同步入口会建立本地虚拟环境。

回归测试：在工作区执行 `.glory-tools/venv/bin/python -m unittest discover -s tools -p 'test_glory*.py'`。

## 检查与调用

脚本通过自身所在目录寻找相邻工具；直接运行 `GLory-v1.0/tools/workspace` 内的入口也可以，不依赖外层 `tools` 快捷链接。`.command` 支持透传参数；在非交互终端中保留退出码，不等待回车或打开 Finder。

在 `GLory` 工作区执行以下只读预检，不会构建、上传或部署：

```bash
./tools/build_apk.sh --sync --check
./tools/build_ipa.sh --update --check
./tools/release_testflight.sh --check
```

资源扫描使用 `./tools/sync_res.sh --dry-run`；它会访问 Drive 并保存扫描清单，但不覆盖资源。当前源为共享目录 `1xjn5Hpa4AzSS8v7hgECEZstHb3dG6m11` 下的 `glory`（`19WnebPCTVXxxjY6pfJjsrAVyVJ0P9mXl`），默认只同步 `assets/`。同步入口是云端到 `res` 的下载工具，不会自动反向上传；打包时再按已有版本规则合并项目与 `res`。

### Drive 固定目录约定（2026-10-06 确认）

- 唯一正式美术资源入口为 [glory/assets](https://drive.google.com/drive/folders/1ksYudI6xNjNemvWaBOw50zKLIWcAYXqu)。美术资源新增、更新及交付均放在此目录对应子目录中；界面图片放在 `assets/ui/`。
- `glory` 下除 `assets/` 以外的文件和目录全部作为历史备份，包括外层 `ui/`、`shaders/`、工程代码、缓存和根目录的 `assets.bundle.json`、`assets.manifest.json`。它们不参与日常资源同步，也不作为当前版本依据；代码以 GitHub 仓库为准。
- 保留当前目录层级和目录 ID，不因同名而合并外层 `ui/` 与 `assets/ui/`。备份恢复须单独明确范围；日常同步不使用 `--all`。
- 已下载的本地文件不会因同步范围收紧而自动删除。

TestFlight 自动上传必须先由账号持有人配置 App Store Connect 团队 API Key。缺少配置时脚本会明确退出，不能仅凭浏览器或 Transporter 已登录判断自动发布可用。配置入口为 `./tools/release_testflight.sh --setup`，本机说明位于 `docs/TestFlight一键发布.md`；密钥必须保存在项目外。

预检通过只说明工具、资源路径和签名配置可用；实际 APK/IPA 导出以及 Apple 处理结果仍以对应构建或发布日志为准。

## 每日同步与双平台内测发布（2026-10-07）

- `./tools/update_sources.sh`：单独更新当前 Git upstream，然后下载正式 Drive `glory/assets`。未提交修改或分叉时停下保留现场；不要 reset/stash 覆盖本地修复。人工先提交本地修复，再合并远端；有冲突时保留本地修复语义。资源回传使用已连接 Drive 对原文件 ID 更新并校验，不把下载脚本误当成双向上传。
- `./tools/build_aab.sh --check`：检查 AAB 环境；`--sync --version-code N` 同步后正式构建。`N` 必须高于 Play 已使用的编号。无人值守签名从本机密钥管理器注入 `GLORY_KEYSTORE_PASSWORD`（私钥密码不同则另设 `GLORY_KEY_PASSWORD`）；不将密码写进脚本、Git 或任务文本。
- `./tools/release_google_play.sh --next-code`：查询远端构建号；`--metadata /绝对路径/aab.json` 上传已验证的正式包并发布到 `internal`。只操作内部轨道，遇到已有审核则停下，不取消其他审核。结果存于 `build/play-releases`；同包重跑先核对版本和哈希，上传结果不明时停止，不能删除状态文件后盲目重传。
- `./tools/release_testflight.sh`：原有 Apple 发布入口，保留并复用。配置外部 API Key 后，自动选择新构建号、上传、等待处理，并加入既有“GLory 内部验证”组。
- `./tools/release_nightly.sh`：依次同步、APK、正式 AAB、Google Play internal、TestFlight。不同平台预检失败会记录失败；不把本地构建算成已发布。`--local --build-only` 可用本地已准备的内容只打包；加 `--unsigned-aab` 可暂不签 AAB。
- 中断后的每日流程用 `--resume build/nightly/对应时间/state.json`，已完成阶段不重复。源提交变化、上一轮上传状态不明或其他发布介入时停止并核对。日志和固定包元数据留在该次目录，APK 上传 Drive 仍由 Chrome UI 完成，不分片。

首次配置：在 `.glory-tools/venv` 安装 `tools/requirements-release.txt`。Google Play 需已创建同包名应用、完成首次控制台配置，并将具备该应用测试发布权限的 OAuth 或 service-account JSON 保存在仓库外，通过 `GLORY_PLAY_CREDENTIALS` 指定。Google 网站密码不是 API 凭据。Apple 团队 API Key 使用 `./tools/release_testflight.sh --setup`。

Google Play 个人测试邮箱名单需在 Console 中把 `zengridong1@163.com` 加入内部测试名单并确认生效；API 的 testers 资源只支持 Google 群组，不支持个人邮箱名单。后续每日版本沿用名单，不反复创建邀请。首次获得的测试加入链接以控制台实际返回为准。TestFlight 沿用既有内部组员；平台收到包、组内可测试、邀请发出、设备安装是不同状态，分别核实。

定时任务由 Codex 在 Asia/Shanghai 每天 20:00 唤醒本聊天，运行本入口并检查平台结果。机器、外置磁盘、网络和所需凭据应可用。没有变更或仍是同一非操作状态时保持安静；完成、失败或需要用户操作时通知。服务器部署属于本次发布步骤，不隐含在每日手机内测任务内。

API 依据：[Google Play 凭据](https://developers.google.com/android-publisher/getting_started)、[内测名单限制](https://developers.google.com/android-publisher/api-ref/rest/v3/edits.testers)、[提交时保护已有审核](https://developers.google.com/android-publisher/api-ref/rest/v3/edits/commit)、[Apple API](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)。
